"""Value types the scanner follows below a manifest entry, and typed method calls.

Our own tables (no third-party text): member names are facts from OpenMW's Lua API
documentation; each status says what omwcompat's runtime implements (runtime/MWSE/lib/omwcompat:
util.lua for Vector/Transform/Color, objects.lua for Cell/Inventory/GameObject, settings.lua for
StorageSection). Used by scan.py:

  * `openmw.self.rotation.getYaw` is a member of the Transform behind the manifest entry
    `openmw.self.rotation`, so it gets the Transform member's status instead of inheriting
    `openmw.self.rotation`'s. A member none of these tables knows is reported as `unlisted`.
  * `cell:getAll(...)`, `inv:countOf(...)`: method calls on values that are not GameObjects are
    counted as typed methods (`Cell:getAll`, `?:getAll` when the receiver is unknown).

`api-audit` compares these tables with OpenMW's own API files when a copy is available.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

STATUS_RANK = {"full": 4, "partial": 3, "stub": 2, "unlisted": 1, "unsupported": 0}

# type -> member -> status. Fields and methods together; kind in TYPE_METHODS below.
_VEC = {"x": "full", "y": "full", "z": "full", "dot": "full", "length": "full", "length2": "full",
        "normalize": "full", "emul": "full", "ediv": "full", "cross": "full", "xy": "full"}
TYPE_MEMBERS: dict[str, dict[str, str]] = {
    "Vector3": _VEC,
    "Transform": {"getYaw": "full", "getPitch": "full", "getAnglesZYX": "full", "getAnglesXZ": "full",
                  "inverse": "full", "apply": "full"},
    "Color": {"r": "full", "g": "full", "b": "full", "a": "full", "asRgb": "full", "asRgba": "full",
              "asHex": "full"},
    "Cell": {"name": "full", "id": "full", "region": "full", "isExterior": "full", "isQuasiExterior": "full",
             "gridX": "full", "gridY": "full", "worldSpaceId": "full", "hasWater": "full", "hasSky": "full",
             "isInSameSpace": "full", "getAll": "partial", "hasTag": "unsupported",
             "displayName": "unsupported", "waterLevel": "unsupported", "pathGrid": "unsupported"},
    "Inventory": {"countOf": "full", "isResolved": "stub", "getAll": "partial", "find": "partial",
                  "findAll": "partial", "resolve": "unsupported"},
    # GameObject.owner (0.4.0): tes3.getOwner / tes3.setOwner; factionRank is MWSE's requiredRank
    "ObjectOwner": {"recordId": "partial", "factionId": "partial", "factionRank": "partial"},
    "StorageSection": {"get": "full", "getCopy": "full", "set": "full", "asTable": "full", "reset": "full",
                       "subscribe": "full", "removeOnExit": "stub", "setLifeTime": "stub"},
    # a string field (cell.id, object.recordId): plain Lua string methods
    "string": {m: "full" for m in ("byte", "find", "format", "gmatch", "gsub", "len", "lower", "match", "rep",
                                   "reverse", "sub", "upper")},
}
# which of the members above are methods (called with `:`)
TYPE_METHODS: dict[str, set[str]] = {
    "Vector3": {"dot", "length", "length2", "normalize", "emul", "ediv", "cross", "xy"},
    "Transform": set(TYPE_MEMBERS["Transform"]),
    "Color": {"asRgb", "asRgba", "asHex"},
    "Cell": {"isInSameSpace", "getAll", "hasTag"},
    "Inventory": set(TYPE_MEMBERS["Inventory"]),
    "StorageSection": set(TYPE_MEMBERS["StorageSection"]),
}
# OpenMW type of each member above when it is itself a value we follow
MEMBER_TYPES = {
    "position": "Vector3", "startingPosition": "Vector3", "rotation": "Transform",
    "startingRotation": "Transform", "cell": "Cell", "startingCell": "Cell", "object": "GameObject",
    "parentContainer": "GameObject", "owner": "ObjectOwner",
    "id": "string", "recordId": "string", "name": "string", "region": "string", "contentFile": "string",
    "worldSpaceId": "string", "ownerRecordId": "string", "displayName": "string",
}
# types _var_types/_recv_type never report as typed-method receivers (counted elsewhere, or plain Lua)
NOT_TYPED_RECEIVERS = {"GameObject", "string"}
# manifest entries whose value is one of the types above (besides MEMBER_TYPES on the last segment)
VALUE_SYMBOLS = {"openmw.util.transform.identity": "Transform"}
# where the OpenMW API files define each type (api-audit)
OPENMW_TYPE_KEYS = {"Vector3": "util#Vector3", "Transform": "util#Transform", "Color": "util#Color",
                    "Cell": "core#Cell", "Inventory": "core#Inventory", "StorageSection": "storage#StorageSection",
                    "GameObject": "core#GameObject"}

# Method names counted even when the receiver's type is unknown (`?:getAll`): distinctive enough
# not to be a mod's own object method most of the time. Generic names (get, set, apply, find,
# reset, ...) are counted only when the receiver's type is known; Lua string/file methods never.
LUA_BUILTIN_METHODS = {"byte", "char", "dump", "find", "format", "gmatch", "gsub", "len", "lower", "match", "rep",
                       "reverse", "sub", "upper", "close", "flush", "lines", "read", "seek", "setvbuf", "write"}
DISTINCTIVE_METHODS = {"getAll", "countOf", "isResolved", "findAll", "getYaw", "getPitch", "getAnglesZYX",
                       "getAnglesXZ", "isInSameSpace", "hasTag", "asRgb", "asRgba", "asHex", "getCopy", "asTable",
                       "length2", "normalize", "emul", "ediv", "cross"}
# `<anything>.name(` calls on a type table the scanner cannot name (t = types[x]; t.createRecordDraft(...))
TYPE_TABLE_FUNCS = {"createRecordDraft", "objectIsInstance"}

# what a call returns, by (module, last segment) of the called symbol; module None: any openmw module
_RETURNS = {
    ("openmw.types", "inventory"): "Inventory", ("openmw.types", "content"): "Inventory",
    ("openmw.world", "getCellByName"): "Cell", ("openmw.world", "getExteriorCell"): "Cell",
    ("openmw.world", "getCellById"): "Cell",
    ("openmw.util", "vector3"): "Vector3",
    ("openmw.util", "rotateX"): "Transform", ("openmw.util", "rotateY"): "Transform",
    ("openmw.util", "rotateZ"): "Transform", ("openmw.util", "move"): "Transform",
    ("openmw.util", "rgb"): "Color", ("openmw.util", "rgba"): "Color", ("openmw.util", "hex"): "Color",
    ("openmw.storage", "globalSection"): "StorageSection", ("openmw.storage", "playerSection"): "StorageSection",
}


def returns(symbol: str) -> str | None:
    """The value type a call of `symbol` returns, when known (types.Actor.inventory -> Inventory)."""
    parts = symbol.split(".")
    if len(parts) < 3:
        return None
    return _RETURNS.get((".".join(parts[:2]), parts[-1]))


def methods_named(name: str) -> dict[str, str]:
    """{type: status} for every value type that has a method `name`."""
    return {t: TYPE_MEMBERS[t][name] for t, ms in TYPE_METHODS.items() if name in ms}


def value_type(symbol: str) -> str | None:
    """The value type behind a manifest entry (openmw.self.rotation -> Transform), else None."""
    if symbol in VALUE_SYMBOLS:
        return VALUE_SYMBOLS[symbol]
    return MEMBER_TYPES.get(symbol.rsplit(".", 1)[-1])


def member_status(typ: str, rest: list[str], game_object: dict) -> str:
    """Status of `rest` (members, outermost first) below a value of type `typ`; `unlisted` when a
    member is not in our tables. game_object: {member: status} built from the manifest."""
    for k, name in enumerate(rest):
        members = game_object if typ == "GameObject" else TYPE_MEMBERS.get(typ, {})
        st = members.get(name)
        if st is None:
            return "unlisted"
        if k == len(rest) - 1:
            return st
        nxt = MEMBER_TYPES.get(name)
        if nxt is None:
            return "unlisted"
        typ = nxt
    return "unlisted"


def game_object_members(manifest: dict) -> dict[str, str]:
    """GameObject fields and methods with omwcompat's status (fields: the `openmw.self.<field>` entry,
    else full; methods: manifest gameObject.methods)."""
    go = manifest.get("gameObject", {})
    syms = manifest.get("symbols", {})
    out = {f: syms.get("openmw.self." + f, "full") for f in go.get("fields", [])}
    out.update(go.get("methods", {}))
    return out


def best_status(statuses) -> str:
    sts = list(statuses)
    if not sts:
        return "unlisted"
    return max(sts, key=lambda s: STATUS_RANK.get(s, 0))
