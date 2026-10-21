defmodule BuildDistro.Storage do
  @moduledoc """
  The S3-compatible bucket that holds artifact bytes.

  Artifacts move between CI, the bucket and devices through presigned URLs.
  The server itself only reads small ranges (for processing) and the icon.
  """

  alias ExAws.S3

  @type part :: %{number: pos_integer(), etag: String.t(), size: non_neg_integer()}

  @spec create_multipart_upload(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_multipart_upload(key, content_type) do
    bucket()
    |> S3.initiate_multipart_upload(key, content_type: content_type)
    |> request()
    |> case do
      {:ok, %{body: %{upload_id: upload_id}}} when upload_id != "" -> {:ok, upload_id}
      {:ok, response} -> {:error, {:unexpected_response, response}}
      error -> error
    end
  end

  @doc """
  The parts the bucket already holds. Multipart uploads are sized so they never
  need more than one page (1,000 parts).
  """
  @spec list_parts(String.t(), String.t()) :: {:ok, [part()]} | {:error, :no_such_upload | term()}
  def list_parts(key, upload_id) do
    bucket()
    |> S3.list_parts(key, upload_id, [{"max-parts", "1000"}])
    |> request()
    |> case do
      {:ok, %{body: %{parts: parts}}} ->
        {:ok,
         parts
         |> Enum.map(fn part ->
           %{
             number: String.to_integer(part.part_number),
             etag: part.etag,
             size: String.to_integer(part.size)
           }
         end)
         |> Enum.sort_by(& &1.number)}

      {:error, {:http_error, 404, _}} ->
        {:error, :no_such_upload}

      error ->
        error
    end
  end

  @spec complete_multipart_upload(String.t(), String.t(), [part()]) :: :ok | {:error, term()}
  def complete_multipart_upload(key, upload_id, parts) do
    bucket()
    |> S3.complete_multipart_upload(key, upload_id, Enum.map(parts, &{&1.number, &1.etag}))
    |> request()
    |> case do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> {:error, :no_such_upload}
      error -> error
    end
  end

  @spec abort_multipart_upload(String.t(), String.t()) :: :ok | {:error, term()}
  def abort_multipart_upload(key, upload_id) do
    bucket()
    |> S3.abort_multipart_upload(key, upload_id)
    |> request()
    |> case do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> :ok
      error -> error
    end
  end

  @spec object_size(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found | term()}
  def object_size(key) do
    bucket()
    |> S3.head_object(key)
    |> request()
    |> case do
      {:ok, %{headers: headers}} ->
        {:ok, headers |> header("content-length") |> String.to_integer()}

      {:error, {:http_error, 404, _}} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  @doc "Reads `length` bytes starting at `offset`."
  @spec read_range(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def read_range(key, offset, length) do
    bucket()
    |> S3.get_object(key, range: "bytes=#{offset}-#{offset + length - 1}")
    |> request()
    |> case do
      {:ok, %{body: body}} when byte_size(body) == length -> {:ok, body}
      {:ok, %{body: body}} -> {:error, {:short_read, byte_size(body), length}}
      error -> error
    end
  end

  @spec read(String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  def read(key) do
    bucket()
    |> S3.get_object(key)
    |> request()
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      error -> error
    end
  end

  @spec put(String.t(), binary(), String.t()) :: :ok | {:error, term()}
  def put(key, body, content_type) do
    bucket()
    |> S3.put_object(key, body, content_type: content_type)
    |> request()
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    bucket()
    |> S3.delete_object(key)
    |> request()
    |> case do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> :ok
      error -> error
    end
  end

  @spec presigned_part_url(String.t(), String.t(), pos_integer(), pos_integer()) :: String.t()
  def presigned_part_url(key, upload_id, part_number, expires_in) do
    presign(:put, key,
      expires_in: expires_in,
      query_params: [{"partNumber", Integer.to_string(part_number)}, {"uploadId", upload_id}]
    )
  end

  @doc "A GET URL for devices and browsers. `filename` makes it a download."
  @spec presigned_download_url(String.t(), pos_integer(), String.t() | nil) :: String.t()
  def presigned_download_url(key, expires_in, filename \\ nil) do
    query_params =
      if filename,
        do: [{"response-content-disposition", ~s(attachment; filename="#{filename}")}],
        else: []

    presign(:get, key, expires_in: expires_in, query_params: query_params)
  end

  @doc "Creates the bucket if it doesn't exist. Used by tests and local development."
  @spec ensure_bucket() :: :ok | {:error, term()}
  def ensure_bucket do
    case bucket() |> S3.head_bucket() |> request() do
      {:ok, _} ->
        :ok

      {:error, {:http_error, 404, _}} ->
        case bucket() |> S3.put_bucket(config().region) |> request() do
          {:ok, _} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  defp presign(method, key, opts) do
    {:ok, url} = S3.presigned_url(ex_aws_config(), method, bucket(), key, opts)
    url
  end

  defp request(operation), do: ExAws.request(operation, ex_aws_config())

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == name, do: value end)
  end

  defp bucket, do: config().bucket

  defp config do
    :build_distro |> Application.fetch_env!(:storage) |> Map.new()
  end

  defp ex_aws_config do
    storage = config()
    endpoint = URI.parse(storage.endpoint)

    ExAws.Config.new(:s3,
      access_key_id: storage.access_key_id,
      secret_access_key: storage.secret_access_key,
      region: storage.region,
      scheme: "#{endpoint.scheme}://",
      host: endpoint.host,
      port: endpoint.port
    )
  end
end
