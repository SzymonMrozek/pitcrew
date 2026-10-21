defmodule BuildDistroWeb.ApiTest do
  use BuildDistroWeb.ConnCase

  alias BuildDistro.Builds
  alias BuildDistro.Workers.ProcessBuild

  setup %{conn: conn} do
    %{project: project, api_key: api_key} = project_fixture()

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> api_key)
      |> put_req_header("accept", "application/json")

    %{conn: conn, project: project, api_key: api_key}
  end

  test "rejects requests without a valid key", %{project: project} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer bd_nope")
      |> post(~p"/api/v1/builds", %{})

    assert json_response(conn, 401)

    {:ok, _} = BuildDistro.Projects.rotate_api_key(project)
    assert build_conn() |> post(~p"/api/v1/builds", %{}) |> json_response(401)
  end

  test "a whole upload over HTTP, retrying every step", %{conn: conn, project: project} do
    ipa = ipa_fixture()
    attrs = start_attrs([{"ipa", ipa}])

    created = conn |> post(~p"/api/v1/builds", attrs) |> json_response(200)
    assert created["state"] == "uploading"
    assert created["url"] =~ "/#{project.slug}/builds/1"
    assert %{"kind" => "ipa", "part_count" => 1, "uploaded" => false} = hd(created["artifacts"])
    assert (conn |> post(~p"/api/v1/builds", attrs) |> json_response(200))["id"] == created["id"]

    parts_path = ~p"/api/v1/builds/#{created["id"]}/artifacts/ipa/parts"

    %{"urls" => %{"1" => url}, "uploaded" => []} =
      conn |> post(parts_path, %{part_numbers: [1]}) |> json_response(200)

    assert %{status: 200} = Req.put!(url, body: ipa, retry: false)

    assert %{"uploaded" => [1], "urls" => %{}} =
             conn |> post(parts_path, %{part_numbers: [1]}) |> json_response(200)

    progress_path = ~p"/api/v1/builds/#{created["id"]}/artifacts/ipa/progress"
    assert conn |> post(progress_path, %{part_number: 1, size: byte_size(ipa)}) |> response(204)

    complete_path = ~p"/api/v1/builds/#{created["id"]}/complete"
    assert %{"state" => "processing"} = conn |> post(complete_path) |> json_response(200)
    assert %{"state" => "processing"} = conn |> post(complete_path) |> json_response(200)

    assert :ok = perform_job(ProcessBuild, %{build_id: created["id"]})

    assert %{"state" => "ready", "version" => "1.4.0", "display_name" => "My App ✓"} =
             conn |> get(~p"/api/v1/builds/#{created["id"]}") |> json_response(200)
  end

  test "answers with what CI needs to recover", %{conn: conn, project: project} do
    data = :crypto.strong_rand_bytes(Builds.part_size(1) + 1)
    created = conn |> post(~p"/api/v1/builds", start_attrs([{"ipa", data}])) |> json_response(200)

    assert %{"error" => "parts are missing", "missing_parts" => [1, 2]} =
             conn |> post(~p"/api/v1/builds/#{created["id"]}/complete") |> json_response(409)

    assert conn
           |> post(~p"/api/v1/builds/#{created["id"]}/artifacts/ipa/parts", %{part_numbers: [9]})
           |> json_response(422)

    assert conn |> get(~p"/api/v1/builds/999999") |> json_response(404)
    assert conn |> post(~p"/api/v1/builds", %{"idempotency_key" => "x"}) |> json_response(422)

    %{project: other, api_key: other_key} = project_fixture()
    other_conn = build_conn() |> put_req_header("authorization", "Bearer " <> other_key)
    assert other_conn |> get(~p"/api/v1/builds/#{created["id"]}") |> json_response(404)
    assert other.id != project.id
  end
end
