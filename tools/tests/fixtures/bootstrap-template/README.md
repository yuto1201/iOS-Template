# Bootstrap template identity fixture

This fixture keeps the app-bootstrap regression runnable after a repository has been converted to an app-specific Identity. It freezes only the template source Identity files selected by `Config/template-identity.json`; it contains no secrets, personal information, or app-specific values.

Refresh the fixture when the bootstrap compatibility regression or the source Identity file-set check fails. From the template repository root, run `ruby tools/tests/lib/bootstrap-fixture.rb refresh .`, review `tools/tests/fixtures/bootstrap-template/source-identity.json`, and commit it with the change.

In a derived app, `test-app-bootstrap.sh` combines the frozen template Identity with the app's current tracked tools in a disposable temporary repository. The app's source, Git index, and Identity record are left untouched.
