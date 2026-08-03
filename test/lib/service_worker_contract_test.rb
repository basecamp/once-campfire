require "test_helper"

class ServiceWorkerContractTest < ActiveSupport::TestCase
  test "push work is registered synchronously and payload parsing stays in the handler" do
    source = Rails.root.join("app/views/pwa/service_worker.js").read

    assert_match(/self\.addEventListener\("push", \(event\) => \{\s*event\.waitUntil\(handlePush\(event\)\)\s*\}\)/m, source)
    assert_match(/async function handlePush\(event\) \{\s*const data = event\.data\.json\(\)\s*await Promise\.all/m, source)
    assert_no_match(/addEventListener\("push", async/, source)
  end
end
