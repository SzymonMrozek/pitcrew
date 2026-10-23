defmodule BuildDistro.PushAdapter do
  def run(request) do
    adapter = Process.get(:push_adapter) || raise "Unexpected push delivery"
    adapter.(request)
  end
end
