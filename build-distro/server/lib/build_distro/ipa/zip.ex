defmodule BuildDistro.IPA.Zip do
  @moduledoc """
  Reads single entries from a zip through a range reader, so a large IPA is
  never downloaded whole: the end of the file, the central directory, then
  only the entries you ask for.

  Sizes and offsets come from the central directory. Local headers written
  with data descriptors carry zeros there.
  """

  defmodule Entry do
    @moduledoc false
    defstruct [:name, :method, :compressed_size, :size, :offset]
  end

  @type reader :: (offset :: non_neg_integer(), length :: pos_integer() ->
                     {:ok, binary()} | {:error, term()})

  @eocd_signature <<0x50, 0x4B, 0x05, 0x06>>
  @eocd64_locator_signature 0x07064B50
  @eocd64_signature 0x06064B50
  @central_signature 0x02014B50
  @local_signature 0x04034B50
  @max_tail 22 + 0xFFFF + 20

  @doc "Lists the entries of a zip of `size` bytes."
  @spec entries(reader(), non_neg_integer()) :: {:ok, [%Entry{}]} | {:error, term()}
  def entries(reader, size) do
    tail_length = min(size, @max_tail)
    tail_offset = size - tail_length

    with {:ok, tail} <- reader.(tail_offset, tail_length),
         {:ok, eocd_at} <- find_eocd(tail),
         {:ok, directory_offset, directory_size} <- directory_location(reader, tail, eocd_at),
         {:ok, directory} <- read(reader, directory_offset, directory_size) do
      parse_directory(directory, [])
    end
  end

  @doc "Reads and inflates one entry, refusing entries larger than `max_size`."
  @spec read_entry(reader(), %Entry{}, pos_integer()) :: {:ok, binary()} | {:error, term()}
  def read_entry(reader, %Entry{} = entry, max_size) do
    with :ok <- check_size(entry, max_size),
         {:ok,
          <<@local_signature::little-32, _::binary-22, name_length::little-16,
            extra_length::little-16>>} <- reader.(entry.offset, 30),
         {:ok, data} <-
           read(reader, entry.offset + 30 + name_length + extra_length, entry.compressed_size) do
      decompress(entry.method, data, entry.size)
    else
      {:ok, _} -> {:error, :bad_local_header}
      error -> error
    end
  end

  defp check_size(%Entry{size: size, compressed_size: compressed}, max)
       when size <= max and compressed <= max,
       do: :ok

  defp check_size(%Entry{name: name}, _), do: {:error, {:entry_too_large, name}}

  defp read(_reader, _offset, 0), do: {:ok, <<>>}
  defp read(reader, offset, length), do: reader.(offset, length)

  defp find_eocd(tail) do
    case :binary.matches(tail, @eocd_signature) do
      [] -> {:error, :not_a_zip}
      matches -> {:ok, matches |> List.last() |> elem(0)}
    end
  end

  defp directory_location(reader, tail, eocd_at) do
    <<_::binary-size(^eocd_at), _sig::binary-4, _disk::little-16, _cd_disk::little-16,
      _disk_entries::little-16, _entries::little-16, cd_size::little-32, cd_offset::little-32,
      _::binary>> = tail

    if cd_offset == 0xFFFFFFFF or cd_size == 0xFFFFFFFF do
      zip64_directory_location(reader, tail, eocd_at)
    else
      {:ok, cd_offset, cd_size}
    end
  end

  defp zip64_directory_location(reader, tail, eocd_at) do
    locator_at = eocd_at - 20

    with true <- locator_at >= 0,
         <<_::binary-size(^locator_at), @eocd64_locator_signature::little-32, _disk::little-32,
           record_offset::little-64, _::binary>> <- tail,
         {:ok,
          <<@eocd64_signature::little-32, _::binary-36, cd_size::little-64, cd_offset::little-64>>} <-
           reader.(record_offset, 56) do
      {:ok, cd_offset, cd_size}
    else
      _ -> {:error, :bad_zip64_directory}
    end
  end

  defp parse_directory(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_directory(
         <<@central_signature::little-32, _made_by::little-16, _needed::little-16,
           _flags::little-16, method::little-16, _time::little-16, _date::little-16,
           _crc::little-32, compressed::little-32, size::little-32, name_length::little-16,
           extra_length::little-16, comment_length::little-16, _disk::little-16,
           _internal::little-16, _external::little-32, offset::little-32,
           name::binary-size(name_length), extra::binary-size(extra_length),
           _comment::binary-size(comment_length), rest::binary>>,
         acc
       ) do
    {size, compressed, offset} = apply_zip64(extra, size, compressed, offset)

    entry = %Entry{
      name: name,
      method: method,
      compressed_size: compressed,
      size: size,
      offset: offset
    }

    parse_directory(rest, [entry | acc])
  end

  defp parse_directory(_, _), do: {:error, :bad_central_directory}

  # Zip64 stores the real values in extra field 0x0001, in this order, only for
  # the fields set to 0xFFFFFFFF in the fixed header.
  defp apply_zip64(extra, size, compressed, offset) do
    case find_extra(extra, 0x0001) do
      nil ->
        {size, compressed, offset}

      data ->
        {size, data} = take64(size, data)
        {compressed, data} = take64(compressed, data)
        {offset, _data} = take64(offset, data)
        {size, compressed, offset}
    end
  end

  defp take64(0xFFFFFFFF, <<value::little-64, rest::binary>>), do: {value, rest}
  defp take64(value, data), do: {value, data}

  defp find_extra(
         <<id::little-16, length::little-16, data::binary-size(length), rest::binary>>,
         wanted
       ) do
    if id == wanted, do: data, else: find_extra(rest, wanted)
  end

  defp find_extra(_, _), do: nil

  defp decompress(0, data, _size), do: {:ok, data}

  defp decompress(8, data, size) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflated = z |> :zlib.inflate(data) |> IO.iodata_to_binary()
      if byte_size(inflated) == size, do: {:ok, inflated}, else: {:error, :bad_inflated_size}
    rescue
      ErlangError -> {:error, :bad_deflate_data}
    after
      :zlib.close(z)
    end
  end

  defp decompress(method, _data, _size), do: {:error, {:unsupported_compression, method}}
end
