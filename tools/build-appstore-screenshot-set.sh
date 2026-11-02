#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: $0 --raw-root DIR --output-root DIR --requirements FILE --review FILE --source-sha SHA --runtime ID --build-digest sha256:HEX [--composition FILE --composed-root DIR]" >&2
  exit 64
}

raw_root= output_root= requirements= review= source_sha= runtime= build_digest= composition= composed_root=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw-root) raw_root=${2-}; shift 2 ;;
    --output-root) output_root=${2-}; shift 2 ;;
    --requirements) requirements=${2-}; shift 2 ;;
    --review) review=${2-}; shift 2 ;;
    --source-sha) source_sha=${2-}; shift 2 ;;
    --runtime) runtime=${2-}; shift 2 ;;
    --build-digest) build_digest=${2-}; shift 2 ;;
    --composition) composition=${2-}; shift 2 ;;
    --composed-root) composed_root=${2-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$raw_root" && -n "$output_root" && -n "$requirements" && -n "$review" && -n "$source_sha" && -n "$runtime" && -n "$build_digest" ]] || usage
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'source SHA must be a full lowercase Git SHA' >&2; exit 1; }
[[ "$build_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'build digest must be sha256: followed by 64 lowercase hexadecimal characters' >&2; exit 1; }
[[ "$runtime" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'runtime identifier is invalid' >&2; exit 1; }
[[ -d "$raw_root" && ! -L "$raw_root" ]] || { echo 'raw root must be a non-symbolic-link directory' >&2; exit 1; }
for file in "$requirements" "$review" "$raw_root/manifest.json"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "required regular file is unavailable: $(basename "$file")" >&2; exit 1; }
done
# #486 (D-101): a composed set names its composition record and the folder that finalize wrote.
if [[ -n "$composition" || -n "$composed_root" ]]; then
  [[ -n "$composition" && -n "$composed_root" ]] || usage
  [[ -f "$composition" && ! -L "$composition" ]] || { echo 'composition record must be a regular file' >&2; exit 1; }
  [[ -d "$composed_root" && ! -L "$composed_root" ]] || { echo 'composed root must be a non-symbolic-link directory' >&2; exit 1; }
  composed_root=$(cd "$composed_root" && /bin/pwd -P)
  composition="$(cd "$(dirname "$composition")" && /bin/pwd -P)/$(basename "$composition")"
fi

raw_root=$(cd "$raw_root" && /bin/pwd -P)
for variable in requirements review; do
  value=${!variable}; directory=$(cd "$(dirname "$value")" && /bin/pwd -P)
  printf -v "$variable" '%s/%s' "$directory" "$(basename "$value")"
done
output_parent=$(cd "$(dirname "$output_root")" && /bin/pwd -P)
output_root="$output_parent/$(basename "$output_root")"
[[ ! -e "$output_root" && ! -L "$output_root" ]] || { echo 'output root already exists; refusing to overwrite it' >&2; exit 1; }
staging=$(mktemp -d "$output_parent/.appstore-screenshots.XXXXXX")
cleanup() { [[ -d "$staging" ]] && rm -rf -- "$staging"; }
trap cleanup EXIT INT TERM

RAW_ROOT="$raw_root" STAGING="$staging" REQUIREMENTS="$requirements" REVIEW="$review" \
SOURCE_SHA="$source_sha" RUNTIME="$runtime" BUILD_DIGEST="$build_digest" \
COMPOSITION="$composition" COMPOSED_ROOT="$composed_root" ruby <<'RUBY'
require "json"
require "digest"
require "fileutils"
require "time"

raw_root=ENV.fetch("RAW_ROOT")
staging=ENV.fetch("STAGING")
requirements_path=ENV.fetch("REQUIREMENTS")
review_path=ENV.fetch("REVIEW")
source_sha=ENV.fetch("SOURCE_SHA")
runtime=ENV.fetch("RUNTIME")
build_digest=ENV.fetch("BUILD_DIGEST")
composition_path=ENV.fetch("COMPOSITION")
composed_root=ENV.fetch("COMPOSED_ROOT")
composed=!composition_path.empty?
errors=[]
add=lambda{|path,code| errors << "#{path}:#{code}"}

parse_json=lambda do |path,label|
  begin
    JSON.parse(File.binread(path))
  rescue JSON::ParserError, Errno::ENOENT
    add.call(label,"invalid-json"); nil
  end
end
exact=lambda do |value,keys,path|
  unless value.is_a?(Hash)
    add.call(path,"object-required"); next false
  end
  missing=keys-value.keys; extra=value.keys-keys
  missing.each{|key| add.call("#{path}.#{key}","missing")}; extra.each{|key| add.call("#{path}.#{key}","unexpected")}
  missing.empty? && extra.empty?
end
safe_relative=lambda do |value,path|
  unless value.is_a?(String) && value.match?(/\A(?:en-US|ja)\/[a-z0-9.-]+\/[0-9]{2}-[a-z0-9-]+\.png\z/) && !value.include?("..")
    add.call(path,"unsafe-path"); next nil
  end
  value
end
png_info=lambda do |path,label|
  begin
    data=File.binread(path)
    unless data.start_with?("\x89PNG\r\n\x1a\n".b)
      add.call(label,"not-png"); next nil
    end
    offset=8; width=height=color_type=nil; alpha=false
    while offset+12<=data.bytesize
      length=data.byteslice(offset,4).unpack1("N"); type=data.byteslice(offset+4,4); payload=data.byteslice(offset+8,length)
      if payload.nil? || offset+12+length>data.bytesize
        add.call(label,"truncated-png"); break
      end
      if type=="IHDR"
        width,height,bit_depth,color_type,compression,filter,interlace=payload.unpack("NNC5")
        add.call(label,"unsupported-png") unless bit_depth==8 && [2,6].include?(color_type) && compression==0 && filter==0 && interlace==0
        alpha ||= color_type==6
      elsif type=="tRNS"
        alpha=true
      elsif type=="IEND"
        break
      end
      offset += 12+length
    end
    unless width && height && color_type
      add.call(label,"missing-ihdr"); next nil
    end
    {"width"=>width,"height"=>height,"alpha"=>alpha,"digest"=>"sha256:#{Digest::SHA256.hexdigest(data)}"}
  rescue Errno::ENOENT, Errno::EACCES
    add.call(label,"missing"); nil
  end
end

requirements=parse_json.call(requirements_path,"requirements")
manifest=parse_json.call(File.join(raw_root,"manifest.json"),"manifest")
review=parse_json.call(review_path,"review")
families={}
if requirements.is_a?(Hash)
  screenshots=requirements["screenshots"]
  if screenshots.is_a?(Hash) && screenshots["requiredFamilies"].is_a?(Array)
    screenshots["requiredFamilies"].each do |entry|
      if entry.is_a?(Hash) && entry["id"].is_a?(String)
        families[entry["id"]]=entry
      else
        add.call("requirements.screenshots.requiredFamilies","invalid")
      end
    end
  else
    add.call("requirements.screenshots","invalid")
  end
end

manifest_keys=%w[schemaVersion sourceSha buildDigest runtime requirementsDigest cases]
case_keys=%w[locale family state order path sourceSha buildDigest runtime deviceType width height digest]
manifest_ok=manifest && exact.call(manifest,manifest_keys,"manifest")
if manifest_ok
  add.call("manifest.schemaVersion","invalid") unless manifest["schemaVersion"]==1
  add.call("manifest.sourceSha","mismatch") unless manifest["sourceSha"]==source_sha
  add.call("manifest.buildDigest","mismatch") unless manifest["buildDigest"]==build_digest
  add.call("manifest.runtime","mismatch") unless manifest["runtime"]==runtime
  expected_requirements="sha256:#{Digest::SHA256.file(requirements_path).hexdigest}"
  add.call("manifest.requirementsDigest","mismatch") unless manifest["requirementsDigest"]==expected_requirements
  add.call("manifest.cases","array-required") unless manifest["cases"].is_a?(Array)
end

review_keys=%w[schemaVersion sourceSha buildDigest visualReviewStatus releaseAuditor cases]
review_case_keys=%w[locale family state path digest safeArea textClipping truthfulRepresentation localeParity]
# A composed set is reviewed twice: the raw capture it shows (truthfulness) and the composed face.
review_case_keys+=%w[rawDigest] if composed
review_ok=review && exact.call(review,review_keys,"review")
review_cases=[]
if review_ok
  add.call("review.schemaVersion","invalid") unless review["schemaVersion"]==1
  add.call("review.sourceSha","mismatch") unless review["sourceSha"]==source_sha
  add.call("review.buildDigest","mismatch") unless review["buildDigest"]==build_digest
  add.call("review.visualReviewStatus","not-passed") unless review["visualReviewStatus"]=="passed"
  auditor=review["releaseAuditor"]
  if exact.call(auditor,%w[status model],"review.releaseAuditor")
    add.call("review.releaseAuditor.status","not-approved") unless auditor["status"]=="approved"
    add.call("review.releaseAuditor.model","invalid") unless auditor["model"].is_a?(String) && !auditor["model"].empty?
  end
  if review["cases"].is_a?(Array)
    review_cases=review["cases"]
    review_cases.each_with_index do |entry,index|
      next unless exact.call(entry,review_case_keys,"review.cases[#{index}]")
      %w[safeArea textClipping truthfulRepresentation localeParity].each do |field|
        add.call("review.cases[#{index}].#{field}","not-passed") unless entry[field]=="passed"
      end
    end
  else
    add.call("review.cases","array-required")
  end
end

cases=manifest.is_a?(Hash) && manifest["cases"].is_a?(Array) ? manifest["cases"] : []
seen_digests={}; seen_keys={}; grouped=Hash.new{|hash,key| hash[key]=[]}; output_cases=[]; raw_index={}
cases.each_with_index do |entry,index|
  path_label="manifest.cases[#{index}]"
  next unless exact.call(entry,case_keys,path_label)
  locale=entry["locale"]; family_id=entry["family"]; state=entry["state"]; order=entry["order"]
  add.call("#{path_label}.locale","invalid") unless %w[en-US ja].include?(locale)
  add.call("#{path_label}.state","invalid") unless state.is_a?(String) && state.match?(/\A[a-z0-9-]+\z/)
  add.call("#{path_label}.order","invalid") unless order.is_a?(Integer) && order.between?(1,10)
  add.call("#{path_label}.sourceSha","mismatch") unless entry["sourceSha"]==source_sha
  add.call("#{path_label}.buildDigest","mismatch") unless entry["buildDigest"]==build_digest
  add.call("#{path_label}.runtime","mismatch") unless entry["runtime"]==runtime
  family=families[family_id]
  unless family
    add.call("#{path_label}.family","unknown"); next
  end
  add.call("#{path_label}.deviceType","not-allowed") unless family["deviceTypes"].is_a?(Array) && family["deviceTypes"].include?(entry["deviceType"])
  relative=safe_relative.call(entry["path"],"#{path_label}.path"); next unless relative
  expected_prefix="#{locale}/#{family_id}/#{format('%02d',order)}-#{state}.png"
  add.call("#{path_label}.path","naming-mismatch") unless relative==expected_prefix
  absolute=File.join(raw_root,relative)
  begin
    stat=File.lstat(absolute)
    unless stat.file? && !stat.symlink? && File.realpath(absolute).start_with?(raw_root+File::SEPARATOR)
      add.call(relative,"unsafe-file"); next
    end
  rescue Errno::ENOENT, Errno::EACCES
    add.call(relative,"missing"); next
  end
  info=png_info.call(absolute,relative); next unless info
  add.call(relative,"alpha-not-allowed") if requirements.dig("screenshots","allowAlpha")==false && info["alpha"]
  add.call(relative,"width-mismatch") unless entry["width"]==info["width"]
  add.call(relative,"height-mismatch") unless entry["height"]==info["height"]
  allowed=(family["portraitSizes"].is_a?(Array) ? family["portraitSizes"] : [])+(family["landscapeSizes"].is_a?(Array) ? family["landscapeSizes"] : [])
  add.call(relative,"dimensions-not-allowed") unless allowed.include?([info["width"],info["height"]])
  add.call(relative,"digest-mismatch") unless entry["digest"]==info["digest"]
  if seen_digests.key?(info["digest"])
    add.call(relative,"duplicate-image")
  else
    seen_digests[info["digest"]]=relative
  end
  key=[locale,family_id,state]
  add.call(path_label,"duplicate-state") if seen_keys.key?(key)
  seen_keys[key]=true
  raw_index[key]=entry.merge("digest"=>info["digest"])
  # A composed set is ordered and reviewed by its composition; the raw captures keep every check above.
  next if composed
  grouped[[locale,family_id]] << order
  matching=review_cases.select{|candidate| candidate.is_a?(Hash) && candidate.values_at("locale","family","state")==key}
  if matching.length!=1
    add.call(relative,"review-missing-or-duplicate")
  else
    check=matching.first
    add.call(relative,"review-path-mismatch") unless check["path"]==relative
    add.call(relative,"review-digest-mismatch") unless check["digest"]==info["digest"]
  end
  output_cases << entry.merge("digest"=>info["digest"])
end

# #486 (D-101): a composed set. Each composed face is bound to exactly one raw capture case, to the
# declaration and the render record that drew it, and to adopted materials only; it must be a real RGB
# PNG without an alpha channel at an allowed size, and English and Japanese keep the same faces in the
# same order. The raw captures above keep every existing check.
composition=nil; composition_digest=nil; structure=Hash.new{|hash,key| hash[key]=[]}
if composed
  digest_pattern=/\Asha256:[0-9a-f]{64}\z/
  composition=parse_json.call(composition_path,"composition")
  composition_digest="sha256:#{Digest::SHA256.file(composition_path).hexdigest}"
  composition_keys=%w[schemaVersion rawManifestDigest captureBatchId sourceSha buildDigest runtime requirementsDigest rendererDigest adoption cases]
  adoption_keys=%w[proposalSheetDigest selectionDigest conceptId decision approvalReference recordedAt provenanceDigest]
  composition_case_keys=%w[locale family state order path rawPath rawDigest declarationDigest renderRecordDigest assetDigests width height digest]
  records={}
  load_record=lambda do |digest,label|
    # A missing or malformed reference is an error: every face needs its validated render record.
    unless digest.is_a?(String) && digest.match?(digest_pattern)
      add.call(label,"record-digest-invalid"); next nil
    end
    next records[digest] if records.key?(digest)
    path=File.join(composed_root,"records","#{digest.sub(":","-")}.json")
    value=begin
      stat=File.lstat(path)
      if stat.file? && !stat.symlink? && "sha256:#{Digest::SHA256.file(path).hexdigest}"==digest
        JSON.parse(File.binread(path))
      end
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      nil
    end
    add.call(label,"record-missing") unless value.is_a?(Hash)
    records[digest]=value.is_a?(Hash) ? value : nil
  end
  adopted=[]
  if composition && exact.call(composition,composition_keys,"composition")
    add.call("composition.schemaVersion","invalid") unless composition["schemaVersion"]==1
    add.call("composition.rawManifestDigest","mismatch") unless composition["rawManifestDigest"]=="sha256:#{Digest::SHA256.file(File.join(raw_root,"manifest.json")).hexdigest}"
    add.call("composition.captureBatchId","invalid") unless composition["captureBatchId"].is_a?(String) && composition["captureBatchId"].match?(/\A[A-Za-z0-9][A-Za-z0-9-]{0,63}\z/)
    add.call("composition.sourceSha","mismatch") unless composition["sourceSha"]==source_sha
    add.call("composition.buildDigest","mismatch") unless composition["buildDigest"]==build_digest
    add.call("composition.runtime","mismatch") unless composition["runtime"]==runtime
    add.call("composition.requirementsDigest","mismatch") unless composition["requirementsDigest"]=="sha256:#{Digest::SHA256.file(requirements_path).hexdigest}"
    add.call("composition.rendererDigest","invalid") unless composition["rendererDigest"].is_a?(String) && composition["rendererDigest"].match?(digest_pattern)
    adoption=composition["adoption"]
    if exact.call(adoption,adoption_keys,"composition.adoption")
      add.call("composition.adoption.decision","not-user-explicit") unless adoption["decision"]=="user-explicit"
      %w[proposalSheetDigest selectionDigest].each do |field|
        add.call("composition.adoption.#{field}","invalid") unless adoption[field].is_a?(String) && adoption[field].match?(digest_pattern)
      end
      add.call("composition.adoption.conceptId","invalid") unless adoption["conceptId"].is_a?(String) && adoption["conceptId"].match?(/\A[A-Za-z0-9][A-Za-z0-9-]{0,31}\z/)
      reference=%r{\A(?:https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/(?:issues|pull)/[0-9]+(?:#issuecomment-[0-9]+)?|(?:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+)\z}
      add.call("composition.adoption.approvalReference","invalid") unless adoption["approvalReference"].is_a?(String) && adoption["approvalReference"].match?(reference)
      begin
        Time.iso8601(adoption["recordedAt"].to_s)
      rescue ArgumentError
        add.call("composition.adoption.recordedAt","invalid")
      end
      provenance_digest=adoption["provenanceDigest"]
      if provenance_digest.nil?
        adopted=[]
      elsif (provenance=load_record.call(provenance_digest,"composition.adoption.provenanceDigest"))
        images=provenance["images"].is_a?(Array) ? provenance["images"] : []
        add.call("composition.adoption.provenanceDigest","invalid") unless provenance["schemaVersion"]==1 && provenance["images"].is_a?(Array)
        adopted=images.select{|image| image.is_a?(Hash) && image.dig("materialReview","decision")=="adopted"}.map{|image| image["sha256"]}
      end
    end
    add.call("composition.cases","array-required") unless composition["cases"].is_a?(Array)
  end
  composed_cases=composition.is_a?(Hash) && composition["cases"].is_a?(Array) ? composition["cases"] : []
  add.call("composition.cases","empty") if composed_cases.empty?
  composed_digests={}; composed_keys={}
  composed_cases.each_with_index do |entry,index|
    path_label="composition.cases[#{index}]"
    next unless exact.call(entry,composition_case_keys,path_label)
    locale=entry["locale"]; family_id=entry["family"]; state=entry["state"]; order=entry["order"]
    add.call("#{path_label}.locale","invalid") unless %w[en-US ja].include?(locale)
    add.call("#{path_label}.state","invalid") unless state.is_a?(String) && state.match?(/\A[a-z0-9-]+\z/)
    unless order.is_a?(Integer) && order.between?(1,10)
      add.call("#{path_label}.order","invalid"); next
    end
    family=families[family_id]
    unless family
      add.call("#{path_label}.family","unknown"); next
    end
    relative=safe_relative.call(entry["path"],"#{path_label}.path"); next unless relative
    add.call("#{path_label}.path","naming-mismatch") unless relative=="#{locale}/#{family_id}/#{format('%02d',order)}-#{state}.png"
    key=[locale,family_id,state]
    add.call(path_label,"duplicate-state") if composed_keys.key?(key)
    composed_keys[key]=true
    raw=raw_index[key]
    if raw.nil?
      add.call(relative,"raw-case-missing")
    else
      add.call(relative,"raw-path-mismatch") unless entry["rawPath"]==raw["path"]
      add.call(relative,"raw-digest-mismatch") unless entry["rawDigest"]==raw["digest"]
    end
    assets=entry["assetDigests"]
    unless assets.is_a?(Array) && assets.all?{|asset| asset.is_a?(String) && asset.match?(digest_pattern)} && assets==assets.uniq.sort
      add.call("#{path_label}.assetDigests","invalid"); assets=[]
    end
    record=load_record.call(entry["renderRecordDigest"],"#{relative}:render-record")
    if record
      files=record["files"].is_a?(Array) ? record["files"] : []; tiles=record["tiles"].is_a?(Array) ? record["tiles"] : []
      unless record["schemaVersion"]==1 && record["renderer"]=="appstore-creative-compose" && record["inputInventory"]=="complete-v1" &&
             record["device"]==family_id && record["locale"]==locale && files.length==tiles.length
        add.call(relative,"render-record-invalid")
      end
      add.call(relative,"declaration-mismatch") unless entry["declarationDigest"].is_a?(String) && record["specSha256"]==entry["declarationDigest"]
      file=files[order-1]; tile=tiles[order-1]
      if file.is_a?(Hash) && file["sha256"]==entry["digest"]
        add.call(relative,"render-size-mismatch") unless file["width"]==entry["width"] && file["height"]==entry["height"]
      else
        add.call(relative,"render-output-mismatch")
      end
      capture=tile.is_a?(Hash) ? tile["capture"] : nil
      listed=record["captures"].is_a?(Array) && record["captures"].any?{|item| item.is_a?(Hash) && item["sha256"]==entry["rawDigest"]}
      add.call(relative,"raw-not-in-render-record") unless capture.is_a?(Hash) && capture["sha256"]==entry["rawDigest"] && listed
      file_path=file.is_a?(Hash) ? file["path"] : nil
      backgrounds=(record["backgrounds"].is_a?(Array) ? record["backgrounds"] : []).select{|item| item.is_a?(Hash) && item["file"]==file_path}.map{|item| item["sourceSha256"]}
      layers=((record["layers"].is_a?(Array) ? record["layers"] : [])+(record["decorations"].is_a?(Array) ? record["decorations"] : []))
        .select{|item| item.is_a?(Hash) && item["tiles"].is_a?(Array) && item["tiles"].include?(order)}.map{|item| item["sha256"]}
      inputs=(backgrounds+layers).uniq.sort
      add.call(relative,"asset-digests-mismatch") unless inputs==assets
      (inputs|assets).each{|asset| add.call(relative,"asset-not-adopted") unless adopted.include?(asset)}
    end
    absolute=File.join(composed_root,relative)
    begin
      stat=File.lstat(absolute)
      unless stat.file? && !stat.symlink? && File.realpath(absolute).start_with?(composed_root+File::SEPARATOR)
        add.call(relative,"unsafe-file"); next
      end
    rescue Errno::ENOENT, Errno::EACCES
      add.call(relative,"missing"); next
    end
    info=png_info.call(absolute,relative); next unless info
    add.call(relative,"alpha-not-allowed") if info["alpha"]
    add.call(relative,"width-mismatch") unless entry["width"]==info["width"]
    add.call(relative,"height-mismatch") unless entry["height"]==info["height"]
    allowed=(family["portraitSizes"].is_a?(Array) ? family["portraitSizes"] : [])+(family["landscapeSizes"].is_a?(Array) ? family["landscapeSizes"] : [])
    add.call(relative,"dimensions-not-allowed") unless allowed.include?([info["width"],info["height"]])
    add.call(relative,"digest-mismatch") unless entry["digest"]==info["digest"]
    if composed_digests.key?(info["digest"])
      add.call(relative,"duplicate-image")
    else
      composed_digests[info["digest"]]=relative
    end
    grouped[[locale,family_id]] << order
    structure[[locale,family_id]] << [order,state]
    matching=review_cases.select{|candidate| candidate.is_a?(Hash) && candidate.values_at("locale","family","state")==key}
    if matching.length!=1
      add.call(relative,"review-missing-or-duplicate")
    else
      check=matching.first
      add.call(relative,"review-path-mismatch") unless check["path"]==relative
      add.call(relative,"review-digest-mismatch") unless check["digest"]==info["digest"]
      add.call(relative,"review-raw-digest-mismatch") unless raw && check["rawDigest"]==raw["digest"]
    end
    next unless raw
    output_cases << {"locale"=>locale,"family"=>family_id,"state"=>state,"order"=>order,"path"=>relative,
      "sourceSha"=>raw["sourceSha"],"buildDigest"=>raw["buildDigest"],"runtime"=>raw["runtime"],"deviceType"=>raw["deviceType"],
      "width"=>info["width"],"height"=>info["height"],"digest"=>info["digest"],"rawDigest"=>raw["digest"]}
  end
  families.each_key do |family_id|
    add.call("screenshots/#{family_id}","locale-structure-mismatch") unless structure[["en-US",family_id]].sort==structure[["ja",family_id]].sort
  end
end

families.each_key do |family_id|
  %w[en-US ja].each do |locale|
    orders=grouped[[locale,family_id]].sort
    add.call("screenshots/#{locale}/#{family_id}","missing #{locale}") if orders.empty?
    add.call("screenshots/#{locale}/#{family_id}","order-not-contiguous") unless orders==((1..orders.length).to_a)
    minimum=requirements.dig("screenshots","minimumPerFamily"); maximum=requirements.dig("screenshots","maximumPerFamily")
    add.call("screenshots/#{locale}/#{family_id}","count-invalid") unless minimum.is_a?(Integer) && maximum.is_a?(Integer) && orders.length.between?(minimum,maximum)
  end
end
add.call("review.cases","set-mismatch") unless review_cases.length==(composed ? composed_cases.length : cases.length)

unless errors.empty?
  warn "screenshot set invalid: #{errors.uniq.sort.join(', ')}"
  exit 1
end

output_cases.sort_by!{|entry| [entry["locale"],entry["family"],entry["order"],entry["state"]]}
output_cases.each do |entry|
  source=File.join(composed ? composed_root : raw_root,entry.fetch("path")); destination=File.join(staging,entry.fetch("path"))
  FileUtils.mkdir_p(File.dirname(destination),mode: 0755)
  FileUtils.copy_file(source,destination)
  File.chmod(0644,destination)
end
final_manifest={
  "schemaVersion"=>1,"sourceSha"=>source_sha,"buildDigest"=>build_digest,"runtime"=>runtime,
  "requirementsDigest"=>"sha256:#{Digest::SHA256.file(requirements_path).hexdigest}",
  "reviewDigest"=>"sha256:#{Digest::SHA256.file(review_path).hexdigest}","cases"=>output_cases
}
if composed
  # The composition record travels with the set, so the package digest binds it (D-101).
  final_manifest=final_manifest.reject{|key,_| key=="cases"}.merge("compositionDigest"=>composition_digest,"cases"=>output_cases)
  FileUtils.copy_file(composition_path,File.join(staging,"composition.json"))
  File.chmod(0644,File.join(staging,"composition.json"))
end
File.binwrite(File.join(staging,"manifest.json"),JSON.generate(final_manifest))
File.chmod(0644,File.join(staging,"manifest.json"))
result={"cases"=>output_cases.length,"manifestDigest"=>"sha256:#{Digest::SHA256.file(File.join(staging,"manifest.json")).hexdigest}","status"=>"ready"}
result["compositionDigest"]=composition_digest if composed
puts JSON.generate(result)
RUBY

/bin/mv "$staging" "$output_root"
staging=
trap - EXIT INT TERM
