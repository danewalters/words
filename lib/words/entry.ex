defmodule Words.Entry do
  @moduledoc """
  A normalized dictionary entry.

  Every provider returns data in its own shape (HTML fragments, JSON,
  attribute-encoded strings), but all of them are normalized into this
  struct. Upper layers never need to know which source an entry came from,
  beyond the `:source` tag.

  Fields that a source cannot supply are left at their defaults:
  a monolingual dictionary leaves `sentence.cn` empty, a source without
  audio sets `audio_url` to `nil`, and so on.
  """

  @enforce_keys [:word, :source]
  defstruct word: nil,
            pronunciations: [],
            definitions: [],
            sentences: [],
            source: nil

  @typedoc "A single pronunciation variant, e.g. UK vs. US."
  @type pronunciation :: %{
          region: String.t() | nil,
          phonetic: String.t(),
          audio_url: String.t() | nil
        }

  @typedoc "Meanings grouped under one part of speech."
  @type definition :: %{pos: String.t(), meanings: [String.t()]}

  @typedoc "An example sentence; `cn` is empty for monolingual sources."
  @type sentence :: %{en: String.t(), cn: String.t()}

  @type t :: %__MODULE__{
          word: String.t(),
          pronunciations: [pronunciation()],
          definitions: [definition()],
          sentences: [sentence()],
          source: atom()
        }
end
