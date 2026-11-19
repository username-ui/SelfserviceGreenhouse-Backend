defmodule Greenhouse.ConfigValidatorTest do
  use ExUnit.Case, async: true

  alias Greenhouse.ConfigValidator

  describe "known_keys/0" do
    test "returns all 21 protocol configuration keys" do
      expected = [
        "tMin",
        "tMax",
        "tHys",
        "ahMin",
        "ahMax",
        "ahHys",
        "shMin",
        "shMax",
        "luxMin",
        "luxMax",
        "luxOnMs",
        "dayStartMs",
        "dayLenMs",
        "pumpMs",
        "pumpIntervalMs",
        "pumpMaxPerDay",
        "sampleMs",
        "turnPerDay",
        "turnMax",
        "turnStep",
        "turnIntervalMs"
      ]

      assert ConfigValidator.known_keys() == expected
    end
  end

  describe "validate_patch/2" do
    test "accepts valid string-key and atom-key patches and ignores unknown keys" do
      assert {:ok, %{"tMin" => 1000, "tMax" => 3000, "tHys" => 150}} =
               ConfigValidator.validate_patch(%{
                 "tMin" => 1000,
                 "tMax" => 3000,
                 "tHys" => 150,
                 "futureFirmwareKey" => "ignored"
               })

      assert {:ok, %{"luxMin" => 0, "luxMax" => 200_000}} =
               ConfigValidator.validate_patch(%{luxMin: 0, luxMax: 200_000, extra: 123})
    end

    test "rejects empty patches or patches with only unknown keys" do
      assert {:error, ["No valid configuration fields provided"]} =
               ConfigValidator.validate_patch(%{})

      assert {:error, ["No valid configuration fields provided"]} =
               ConfigValidator.validate_patch(%{"unknown" => 1, :other => 2})

      assert {:error, ["Configuration payload must be a map"]} =
               ConfigValidator.validate_patch(nil)
    end

    test "rejects non-integer values including floats, strings, booleans, and nil" do
      for bad_val <- [23.5, "1000", true, false, nil, [1000], %{}] do
        assert {:error, errors} = ConfigValidator.validate_patch(%{"tMin" => bad_val})
        assert Enum.any?(errors, &String.contains?(&1, "tMin"))
      end
    end

    test "does not crash cross-field checks when one field is non-integer" do
      assert {:error, ["tMin must be an integer"]} =
               ConfigValidator.validate_patch(%{"tMin" => "bad", "tMax" => 3000})

      assert {:error, ["tHys must be an integer"]} =
               ConfigValidator.validate_patch(%{
                 "tMin" => 1000,
                 "tMax" => 3000,
                 "tHys" => true
               })
    end

    test "validates temperature, air humidity, soil humidity, and lux boundaries" do
      assert {:ok, _} = ConfigValidator.validate_patch(%{"tMin" => -1000, "tMax" => 5000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"tMin" => -1001})
      assert {:error, _} = ConfigValidator.validate_patch(%{"tMax" => 5001})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"tHys" => 1})
      assert {:ok, _} = ConfigValidator.validate_patch(%{"tHys" => 6000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"tHys" => 0})
      assert {:error, _} = ConfigValidator.validate_patch(%{"tHys" => 6001})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"ahMin" => 0, "ahMax" => 10_000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"ahMin" => -1})
      assert {:error, _} = ConfigValidator.validate_patch(%{"ahMax" => 10_001})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"ahHys" => 1})
      assert {:ok, _} = ConfigValidator.validate_patch(%{"ahHys" => 10_000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"ahHys" => 0})
      assert {:error, _} = ConfigValidator.validate_patch(%{"ahHys" => 10_001})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"shMin" => 0, "shMax" => 10_000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"shMin" => -1})
      assert {:error, _} = ConfigValidator.validate_patch(%{"shMax" => 10_001})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"luxMin" => 0, "luxMax" => 200_000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"luxMin" => -1})
      assert {:error, _} = ConfigValidator.validate_patch(%{"luxMax" => 200_001})
    end

    test "validates time window, pump, sample, and turntable field boundaries" do
      assert {:ok, _} = ConfigValidator.validate_patch(%{"luxOnMs" => 0})
      assert {:ok, _} = ConfigValidator.validate_patch(%{"luxOnMs" => 86_400_000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"luxOnMs" => -1})
      assert {:error, _} = ConfigValidator.validate_patch(%{"luxOnMs" => 86_400_001})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"dayStartMs" => 0})
      assert {:ok, _} = ConfigValidator.validate_patch(%{"dayStartMs" => 86_399_999})
      assert {:error, _} = ConfigValidator.validate_patch(%{"dayStartMs" => -1})
      assert {:error, _} = ConfigValidator.validate_patch(%{"dayStartMs" => 86_400_000})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"dayLenMs" => 60_000})
      assert {:ok, _} = ConfigValidator.validate_patch(%{"dayLenMs" => 86_400_000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"dayLenMs" => 59_999})
      assert {:error, _} = ConfigValidator.validate_patch(%{"dayLenMs" => 86_400_001})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"pumpMs" => 1})
      assert {:ok, _} = ConfigValidator.validate_patch(%{"pumpMs" => 600_000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"pumpMs" => 0})
      assert {:error, _} = ConfigValidator.validate_patch(%{"pumpMs" => 600_001})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"pumpIntervalMs" => 1})
      assert {:error, _} = ConfigValidator.validate_patch(%{"pumpIntervalMs" => 0})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"pumpMaxPerDay" => 1})
      assert {:ok, _} = ConfigValidator.validate_patch(%{"pumpMaxPerDay" => 12})
      assert {:error, _} = ConfigValidator.validate_patch(%{"pumpMaxPerDay" => 0})
      assert {:error, _} = ConfigValidator.validate_patch(%{"pumpMaxPerDay" => 13})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"sampleMs" => 10})
      assert {:ok, _} = ConfigValidator.validate_patch(%{"sampleMs" => 60_000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"sampleMs" => 9})
      assert {:error, _} = ConfigValidator.validate_patch(%{"sampleMs" => 60_001})

      for divisor <- [1, 2, 3, 4, 5, 6, 9, 10, 12, 15, 18, 20, 30, 36, 45, 60, 90, 180] do
        assert {:ok, _} = ConfigValidator.validate_patch(%{"turnPerDay" => divisor})
      end

      for invalid <- [0, -3, 7, 11, 13, 360] do
        assert {:error, _} = ConfigValidator.validate_patch(%{"turnPerDay" => invalid})
      end

      assert {:ok, _} = ConfigValidator.validate_patch(%{"turnMax" => 0})
      assert {:ok, _} = ConfigValidator.validate_patch(%{"turnMax" => 180})
      assert {:error, _} = ConfigValidator.validate_patch(%{"turnMax" => -1})
      assert {:error, _} = ConfigValidator.validate_patch(%{"turnMax" => 181})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"turnStep" => 1})
      assert {:ok, _} = ConfigValidator.validate_patch(%{"turnStep" => 180})
      assert {:error, _} = ConfigValidator.validate_patch(%{"turnStep" => 0})
      assert {:error, _} = ConfigValidator.validate_patch(%{"turnStep" => 181})

      assert {:ok, _} = ConfigValidator.validate_patch(%{"turnIntervalMs" => 1000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"turnIntervalMs" => 999})
    end

    test "validates cross-field consistency within patch and against existing config" do
      assert {:error, _} = ConfigValidator.validate_patch(%{"tMin" => 3000, "tMax" => 3000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"tMin" => 4000, "tMax" => 3000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"ahMin" => 5000, "ahMax" => 5000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"shMin" => 6000, "shMax" => 5000})
      assert {:error, _} = ConfigValidator.validate_patch(%{"luxMin" => 1000, "luxMax" => 900})

      # Cross-field check against existing_raw_config
      existing = %{"tMin" => 1000, "tMax" => 3000, "tHys" => 500, "pumpMs" => 10_000}

      assert {:error, _} = ConfigValidator.validate_patch(%{"tMin" => 3500}, existing)
      assert {:error, _} = ConfigValidator.validate_patch(%{"tMax" => 1500}, existing)
      assert {:ok, _} = ConfigValidator.validate_patch(%{"tMax" => 1501}, existing)

      assert {:error, _} = ConfigValidator.validate_patch(%{"pumpIntervalMs" => 9_999}, existing)
      assert {:ok, _} = ConfigValidator.validate_patch(%{"pumpIntervalMs" => 10_000}, existing)

      assert {:error, _} =
               ConfigValidator.validate_patch(%{"ahMin" => 2000, "ahMax" => 2500, "ahHys" => 500})

      assert {:ok, _} =
               ConfigValidator.validate_patch(%{"ahMin" => 2000, "ahMax" => 2500, "ahHys" => 499})

      assert {:error, _} =
               ConfigValidator.validate_patch(%{"tMin" => 2000, "tMax" => 2500, "tHys" => 500})

      assert {:ok, _} =
               ConfigValidator.validate_patch(%{"tMin" => 2000, "tMax" => 2500, "tHys" => 499})

      assert {:error, _} =
               ConfigValidator.validate_patch(%{"turnStep" => 30}, %{"turnMax" => 20})

      assert {:ok, _} =
               ConfigValidator.validate_patch(%{"turnStep" => 20}, %{"turnMax" => 20})
    end
  end

  describe "to_human/1 and from_human/1" do
    test "converts temperature and humidity fields while preserving other keys" do
      raw = %{
        "tMin" => -1000,
        "tMax" => 3050,
        "tHys" => 150,
        "ahMin" => 4000,
        "ahMax" => 8550,
        "ahHys" => 250,
        "shMin" => 2000,
        "shMax" => 7525,
        "luxMin" => 500,
        "pumpMs" => 5000
      }

      human = ConfigValidator.to_human(raw)

      assert human == %{
               "tMin" => -10.0,
               "tMax" => 30.5,
               "tHys" => 1.5,
               "ahMin" => 40.0,
               "ahMax" => 85.5,
               "ahHys" => 2.5,
               "shMin" => 20.0,
               "shMax" => 75.25,
               "luxMin" => 500,
               "pumpMs" => 5000
             }

      assert ConfigValidator.from_human(human) == raw
    end

    test "from_human normalizes atom keys, handles floats accurately, and preserves invalid values for validation" do
      converted =
        ConfigValidator.from_human(%{
          tMin: 19.99,
          tMax: 25,
          tHys: 1.5,
          luxMin: 300,
          unknown: "x"
        })

      assert converted == %{
               "tMin" => 1999,
               "tMax" => 2500,
               "tHys" => 150,
               "luxMin" => 300,
               "unknown" => "x"
             }

      assert {:ok, %{"tMin" => 1999, "tMax" => 2500, "tHys" => 150, "luxMin" => 300}} =
               ConfigValidator.validate_patch(converted)

      bad = ConfigValidator.from_human(%{"tMin" => "23.5", "ahMin" => true})
      assert bad == %{"tMin" => "23.5", "ahMin" => true}
      assert {:error, errors} = ConfigValidator.validate_patch(bad)
      assert length(errors) == 2
    end
  end
end
