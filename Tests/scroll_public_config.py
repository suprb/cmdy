"""Pure reconstruction of supported installed-default/config-validation evidence.

The public CLI validates the exact owned file and reports installed defaults
separately. This does not claim to introspect the running GUI configuration.
The existing exact launch/config and observed wheel mapping remain mandatory.
"""
import hashlib
import math
import re

WANTED = frozenset({"mouse-scroll-multiplier", "font-family", "font-style", "font-size"})
SCOPE = "installed defaults plus validated exact owned launch configuration"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def selected_values(text):
    values = {}
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if separator and key.strip() in WANTED:
            values.setdefault(key.strip(), []).append(value.strip())
    return values


def discrete_multiplier(values):
    require(isinstance(values, list) and bool(values), "missing discrete multiplier")
    found = []
    precision_count = 0
    for value in values:
        require(isinstance(value, str), "invalid multiplier type")
        for item in value.split(","):
            item = item.strip()
            if item.startswith("discrete:"):
                number = item.split(":", 1)[1]
                require(re.fullmatch(r"\d+(?:\.\d+)?", number) is not None,
                        "invalid discrete multiplier syntax")
                found.append(float(number))
            elif item.startswith("precision:"):
                precision_count += 1
                require(precision_count == 1, "duplicate precision multiplier")
                number = item.split(":", 1)[1]
                require(re.fullmatch(r"\d+(?:\.\d+)?", number) is not None,
                        "invalid precision multiplier syntax")
                require(math.isfinite(float(number)) and .01 <= float(number) <= 10000,
                        "precision multiplier is outside documented bounds")
            elif re.fullmatch(r"\d+(?:\.\d+)?", item):
                found.append(float(item))
            else:
                raise ValueError("unknown scroll multiplier syntax")
    require(len(found) == 1 and math.isfinite(found[0]) and .01 <= found[0] <= 10000,
            "ambiguous/unavailable/out-of-bounds discrete multiplier")
    return found[0]


def validate_public_policy(record, binary, binary_sha256, config_path, config_text, profile):
    require(record.get("schemaVersion") == 2 and type(record.get("schemaVersion")) is int
            and record.get("scope") == SCOPE, "missing supported public configuration contract")
    require(profile in ("matched", "cmdy-defaults"), "unknown profile")
    require(record["binarySHA256Before"] == record["binarySHA256After"] == binary_sha256,
            "public CLI executable identity differs")
    require(record["configSHA256Before"] == record["configSHA256After"]
            == hashlib.sha256(config_text.encode()).hexdigest(), "validated config bytes changed")
    defaults, validation = record["defaultQuery"], record["configurationValidation"]
    require(defaults["arguments"] == [str(binary), "+show-config", "--default"]
            and type(defaults["returncode"]) is int and defaults["returncode"] == 0
            and defaults["stderr"] == "", "installed default query failed or could load user configuration")
    require(validation["arguments"] == [str(binary), "+validate-config", f"--config-file={config_path}"]
            and type(validation["returncode"]) is int and validation["returncode"] == 0
            and validation["stdout"] == "" and validation["stderr"] == "",
            "exact owned configuration did not validate without diagnostics")
    selected = defaults["selectedValues"]
    require(isinstance(selected, dict) and set(selected) <= WANTED
            and "mouse-scroll-multiplier" in selected, "missing installed discrete default")
    default = discrete_multiplier(selected["mouse-scroll-multiplier"])
    configured = selected_values(config_text)
    # The complete config is independently required to equal the generated
    # registered profile. Reject nesting here too: these bytes must be the
    # complete additional input, with default-file loading disabled at launch.
    for line in config_text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        key, separator, _ = line.partition("=")
        require(not separator or key.strip() not in ("config-file", "config-default-files"),
                "nested/default config directive is outside this exact-input proof")
    if profile == "matched":
        require(configured.get("mouse-scroll-multiplier") == ["discrete:1"],
                "matched profile must explicitly configure discrete:1")
        effective = discrete_multiplier(configured["mouse-scroll-multiplier"])
        origin = "validated-explicit-override"
    else:
        require("mouse-scroll-multiplier" not in configured, "default profile changed scroll multiplier")
        effective, origin = default, "installed-default"
    expected = {"installedDefaultDiscreteMultiplier": default,
                "validatedDiscreteMultiplier": effective, "policyOrigin": origin}
    require(isinstance(record["policy"], dict)
            and type(record["policy"].get("installedDefaultDiscreteMultiplier")) in (int, float)
            and type(record["policy"].get("validatedDiscreteMultiplier")) in (int, float),
            "invalid derived policy numeric types")
    require(record["policy"] == expected, "derived scroll policy contradicts installed/default file evidence")
    return expected
