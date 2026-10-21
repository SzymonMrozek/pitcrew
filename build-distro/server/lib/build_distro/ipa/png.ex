defmodule BuildDistro.IPA.PNG do
  @moduledoc """
  Converts Apple's crushed PNGs (a `CgBI` chunk, raw deflate, BGRA pixels)
  into standard PNGs that browsers can show. Standard PNGs pass through.
  """

  @signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>

  @spec normalize(binary()) :: {:ok, binary()} | {:error, term()}
  def normalize(<<@signature, rest::binary>> = png) do
    with {:ok, chunks} <- chunks(rest, []) do
      case chunks do
        [{"CgBI", _} | chunks] -> uncrush(chunks)
        _ -> {:ok, png}
      end
    end
  end

  def normalize(_), do: {:error, :not_a_png}

  defp chunks(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp chunks(
         <<length::32, type::binary-4, data::binary-size(length), _crc::32, rest::binary>>,
         acc
       ) do
    chunks = [{type, data} | acc]
    if type == "IEND", do: {:ok, Enum.reverse(chunks)}, else: chunks(rest, chunks)
  end

  defp chunks(_, _), do: {:error, :bad_png}

  defp uncrush(chunks) do
    with {"IHDR", <<width::32, height::32, 8, 6, _::binary>> = header} <-
           List.keyfind(chunks, "IHDR", 0),
         {:ok, pixels} <- inflate_raw(for({"IDAT", data} <- chunks, do: data)),
         true <- byte_size(pixels) == height * (1 + width * 4) do
      row_size = 1 + width * 4
      rows = for <<row::binary-size(^row_size) <- pixels>>, do: swap_row(row)

      {:ok,
       IO.iodata_to_binary([
         @signature,
         chunk("IHDR", header),
         chunk("IDAT", :zlib.compress(rows)),
         chunk("IEND", <<>>)
       ])}
    else
      _ -> {:error, :unsupported_crushed_png}
    end
  end

  # Each PNG filter works per byte against the same channel of a neighbouring
  # pixel, so swapping channels in the filtered data stays valid.
  defp swap_row(<<filter, pixels::binary>>) do
    [filter | for(<<b, g, r, a <- pixels>>, do: <<r, g, b, a>>)]
  end

  defp inflate_raw(parts) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      {:ok, z |> :zlib.inflate(parts) |> IO.iodata_to_binary()}
    rescue
      ErlangError -> {:error, :bad_deflate_data}
    after
      :zlib.close(z)
    end
  end

  defp chunk(type, data) do
    [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
  end
end
