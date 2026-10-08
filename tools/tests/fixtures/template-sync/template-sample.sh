# Sourced by the template sync regressions (D-074, #259). It builds the template sample those tests
# change. In the template itself, the sample is its tracked files, as before. In a repository derived
# from the template (D-073: a recorded template base, or an Identity record), it is the same files
# rebuilt with the frozen template Identity (#156), without the app's own records and without paths
# the template's ownership manifest does not classify. The running repository is only read.

template_sample_derived() {
  [[ -e "$1/Config/app-identity.json" || -e "$1/Config/template-base.json" ]]
}

# build_template_sample ROOT DESTINATION: DESTINATION must not exist and must be in the temporary area.
build_template_sample() {
  local root=$1 destination=$2
  if ! template_sample_derived "$root"; then
    mkdir -p "$destination"
    (cd "$root" && git ls-files -z | tar --null -T - -cf "$destination.tar")
    tar -x -f "$destination.tar" -C "$destination"
    rm -f "$destination.tar"
    return
  fi
  ruby "$root/tools/tests/lib/bootstrap-fixture.rb" create "$root" "$destination" >/dev/null
  ruby -r"$destination/tools/lib/template-sync.rb" -e '
    root = ARGV.fetch(0)
    ownership = TemplateSync.load_ownership(File.read(File.join(root, TemplateSync::OWNERSHIP_PATH)))
    TemplateSync.tracked_paths(root, "HEAD").each do |path|
      next if path != TemplateSync::BASE_RECORD_PATH && TemplateSync.classify(ownership, path)
      File.delete(File.join(root, path))
    end
  ' "$destination"
  rm -rf "$destination/.git"
}
