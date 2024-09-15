extends Control

var data_pak_initialized: bool = false
var data_pak: PackedByteArray
var data: String
var pos: int
var cache: Array = []
var scache: Array = []
var cur_string_table: Array = []
var seen_sprites: Array = []

var njs_dialog: FileDialog
var pak_dialog: FileDialog

var njs_location: String
var pak_location: String

func _ready() -> void:
    DisplayServer.window_set_min_size(Vector2i(580, 230))
    njs_location = "D:/workspace/godot/N.js"
    pak_location = "D:/workspace/godot/default.pak"
    extract_sprites()

func _on_find_njs_pressed() -> void:
    njs_dialog = FileDialog.new()
    njs_dialog.access = FileDialog.ACCESS_FILESYSTEM
    njs_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
    njs_dialog.file_selected.connect(_select_njs)
    njs_dialog.filters = ["*.js;Javascript Files"]
    njs_dialog.popup(Rect2i(get_window().position, Vector2i(600, 400)))
    add_child(njs_dialog)

func _on_find_default_pak_pressed() -> void:
    pak_dialog = FileDialog.new()
    pak_dialog.access = FileDialog.ACCESS_FILESYSTEM
    pak_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
    pak_dialog.file_selected.connect(_select_pak)
    pak_dialog.filters = ["*.pak;PAK file"]
    pak_dialog.popup(Rect2i(get_window().position, Vector2i(600, 400)))
    add_child(pak_dialog)

func _select_njs(path: String) -> void:
    njs_location = path
    $VBoxContainer/HBoxContainer/NJSLocation.text = path
    njs_dialog.queue_free()

func _select_pak(path: String) -> void:
    pak_location = path
    $VBoxContainer/HBoxContainer2/PakLocation.text = path
    pak_dialog.queue_free()

func _on_export_button_pressed() -> void:
    if pak_location != "" and njs_location != "":
        extract_sprites()
    else:
        log_textbox("Select N.js and default.pak locations before exporting\n")

func extract_sprites() -> void:
    await log_textbox("Loading file listing from N.js...")
    var file_contents: String = FileAccess.get_file_as_string(njs_location)
    var start_idx: int = file_contents.find("\"assets\"")
    start_idx = file_contents.rfind("'", start_idx) + 1
    var end_idx: int = file_contents.find("'", start_idx)
    var json_blob: String = file_contents.substr(start_idx, end_idx - start_idx)
    var parsed_json: Dictionary = JSON.parse_string(json_blob)
    data = parsed_json.assets
    pos = 0
    var file_listing: Array = unserialize() as Array
    log_textbox(" Done\n")

    await log_textbox("Scanning default.pak for Sprites...")
    var file_dict: Dictionary = {}
    var all: Array = []
    for listing: Variant in file_listing:
        # We're not using this dictionary, just try parsing everything and collect seen_sprites
        file_dict[listing.id] = listing
        if listing.id.ends_with(".mbs"):
            all.push_back(parse_mbs(unpack(listing)))
    log_textbox(" Done\n")

    await log_textbox("Writing Sprite data to idleon-sprite-data.json...")
    var out: FileAccess = FileAccess.open("idleon-sprite-data.json", FileAccess.WRITE)
    out.store_string(JSON.stringify(seen_sprites))
    out.close()
    log_textbox(" Done\n")

    await log_textbox("Writing all data to idleon-all-data.json...")
    var out2: FileAccess = FileAccess.open("idleon-all-data.json", FileAccess.WRITE)
    out2.store_string(JSON.stringify(all))
    out2.close()
    log_textbox(" Done\n")

    # Make sure you move the files out of the godot project if you use this, otherwise it imports all 10k+ files unnecessarily
    #dump_listing(file_listing)

    # Clear out all loaded info
    data_pak_initialized = false
    data_pak.clear()
    data = ""
    pos = 0
    cache.clear()
    scache.clear()
    cur_string_table.clear()
    seen_sprites.clear()

func log_textbox(text: String) -> void:
    $VBoxContainer/LoggingPanel/LoggingLabel.text += text
    await get_tree().create_timer(0.1).timeout

func dump_listing(file_listing: Array) -> void:
    for listing: Variant in file_listing:
        var idx: int = listing.id.rfind("/")
        if idx != -1:
            DirAccess.open("res://").make_dir_recursive(listing.id.substr(0, idx))

        var file: FileAccess = FileAccess.open(listing.id, FileAccess.WRITE)
        if file == null:
            print(FileAccess.get_open_error())
            continue
        file.store_buffer(unpack(listing))
        file.close()

func parse_mbs_dynamic(stream: StreamPeerBuffer) -> Variant:
    var reset_pos: int = stream.get_position() + 8
    var obj_type: int = stream.get_32()

    var result: Variant
    if obj_type == 4:
        var list_addr: int = stream.get_32()
        result = parse_mbs_inner(stream, list_addr, obj_type)
    elif obj_type < 7:
        result = parse_mbs_inner(stream, stream.get_position(), obj_type)
    else:
        var obj_addr: int = stream.get_32()
        result = parse_mbs_inner(stream, obj_addr, obj_type)

    stream.seek(reset_pos)
    return result

# To parse a new type, add the appropriate type code as a case
# Type code reference numbers are at the bottom of this file
# Not all numbers here have been fully implemented (look for return null)
# If a type is used in a list, it additionally needs a size added to the LIST case (type code 4)
func parse_mbs_inner(stream: StreamPeerBuffer, addr: int, type_code: int) -> Variant:
    stream.seek(addr)
    match type_code:
        0: #BOOLEAN
            return (stream.get_8() != 0)

        1: #INTEGER
            return stream.get_32()

        2: #FLOAT
            return stream.get_float()

        3: #STRING
            var string_idx: int = stream.get_32()
            return cur_string_table[string_idx]

        4: # LIST
            if addr == 0:
                # TODO: Is this correct?
                return []
            var size: int = stream.get_32()
            var list_type: int = stream.get_32()
            var cur_addr: int = stream.get_position()
            var list: Array = []
            for i: int in range(0, size):
                list.push_back(parse_mbs_inner(stream, cur_addr, list_type))
                if list_type == 1:
                    cur_addr += 4
                elif list_type == 3:
                    cur_addr += 4
                elif list_type == 5:
                    cur_addr += 8
                elif list_type == 13:
                    cur_addr += 8
                elif list_type == 18:
                    cur_addr += 50
                elif list_type == 19:
                    cur_addr += 33
                elif list_type == 21:
                    cur_addr += 13
                elif list_type == 22:
                    cur_addr += 8
                elif list_type == 24:
                    cur_addr += 8
                elif list_type == 25:
                    cur_addr += 12
                elif list_type == 29:
                    cur_addr += 49
                elif list_type == 39:
                    cur_addr += 28
                elif list_type == 41:
                    cur_addr += 8
                elif list_type == 47:
                    cur_addr += 50
                elif list_type == 48:
                    cur_addr += 37
                elif list_type == 49:
                    cur_addr += 12
                elif list_type == 50:
                    cur_addr += 18
                elif list_type == 51:
                    cur_addr += 9
                elif list_type == 52:
                    cur_addr += 16
                elif list_type == 53:
                    cur_addr += 12
                else:
                    assert(false, "Missing list size for " + str(list_type))
            return list

        5: #DYNAMIC
            return parse_mbs_dynamic(stream)

        6: #NULL
            return null

        11: #MBS_BACKGROUND
            var result: Dictionary = {}
            result.actorID = stream.get_32()
            result.description = cur_string_table[stream.get_32()]
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.readableImages = stream.get_8() != 0
            var durations_addr: int = stream.get_32()
            result.height = stream.get_32()
            result.numFrames = stream.get_32()
            result.repeats = stream.get_8() != 0
            result.resized = stream.get_8() != 0
            result.width = stream.get_32()
            result.xParallaxFactor = stream.get_float()
            result.xVelocity = stream.get_float()
            result.yParallaxFactor = stream.get_float()
            result.yVelocity = stream.get_float()

            result.durations = parse_mbs_inner(stream, durations_addr, 4)
            return result

        12: #MBS_CUSTOM_BLOCK
            var result: Dictionary = {}
            result.actorID = stream.get_32()
            result.description = cur_string_table[stream.get_32()]
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.blocktag = cur_string_table[stream.get_32()]
            result.blocktype = cur_string_table[stream.get_32()]
            result.code = cur_string_table[stream.get_32()]
            result.global = stream.get_8() != 0
            result.gui = cur_string_table[stream.get_32()]
            result.message = cur_string_table[stream.get_32()]
            result.returnType = cur_string_table[stream.get_32()]
            result.snippetID = stream.get_32()
            var blanks_addr: int = stream.get_32()

            result.blanks = parse_mbs_inner(stream, blanks_addr, 4)
            return result

        13: #MBS_BLANK
            var result: Dictionary = {}
            result.name = cur_string_table[stream.get_32()]
            result.type = cur_string_table[stream.get_32()]
            return result

        14: #MBS_FONT
            var result: Dictionary = {}
            result.actorID = stream.get_32()
            result.description = cur_string_table[stream.get_32()]
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.alphabet = cur_string_table[stream.get_32()]
            result.readableImages = stream.get_8() != 0
            result.height = stream.get_32()
            result.offsets = cur_string_table[stream.get_32()]
            result.prerendered = stream.get_8() != 0
            result.rowHeight = stream.get_32()
            return result

        15: #MBS_MUSIC
            var result: Dictionary = {}
            result.actorID = stream.get_32()
            result.description = cur_string_table[stream.get_32()]
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.loop = stream.get_8() != 0
            result.pan = stream.get_32()
            result.stream = stream.get_8() != 0
            result.type = cur_string_table[stream.get_32()]
            result.volume = stream.get_32()
            return result

        16: #MBS_ACTOR_TYPE
            var result: Dictionary = {}
            result.actorID = stream.get_32()
            result.description = cur_string_table[stream.get_32()]
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.angularDamping = stream.get_float()
            result.autoScale = stream.get_8() != 0
            result.bodyType = stream.get_32()
            result.continuous = stream.get_8() != 0
            result.eventSnippetID = stream.get_32()
            result.fixedRotation = stream.get_8() != 0
            result.friction = stream.get_float()
            result.groupID = stream.get_32()
            result.ignoreGravity = stream.get_8() != 0
            result.inertia = stream.get_float()
            result.linearDamping = stream.get_float()
            result.mass = stream.get_float()
            result.pausable = stream.get_8() != 0
            result.physicsMode = stream.get_32()
            result.restitution = stream.get_float()
            result.sprite = stream.get_32()
            result.isStatic = stream.get_8() != 0
            var snippets_addr: int = stream.get_32()

            result.snippets = parse_mbs_inner(stream, snippets_addr, 4)
            return result

        17: #MBS_SPRITE
            var result: Dictionary = {}
            result.actorID = stream.get_32()
            result.description = cur_string_table[stream.get_32()]
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.defaultAnimation = stream.get_32()
            result.readableImages = stream.get_8() != 0
            result.height = stream.get_32()
            result.width = stream.get_32()
            var animations_addr: int = stream.get_32()

            result.animations = parse_mbs_inner(stream, animations_addr, 4)
            seen_sprites.push_back(result)
            return result

        18: #MBS_ANIMATION
            var result: Dictionary = {}
            result.across = stream.get_32()
            result.down = stream.get_32()
            var durations_addr: int = stream.get_32()
            result.height = stream.get_32()
            result.id = stream.get_32()
            result.loop = stream.get_8() != 0
            result.name = cur_string_table[stream.get_32()]
            result.numFrames = stream.get_32()
            result.originX = stream.get_32()
            result.originY = stream.get_32()
            result.sync = stream.get_8() != 0
            result.version = stream.get_32()
            result.width = stream.get_32()
            var shapes_addr: int = stream.get_32()

            result.durations = parse_mbs_inner(stream, durations_addr, 4)
            result.shapes = parse_mbs_inner(stream, shapes_addr, 4)
            return result

        19: #MBS_ANIM_SHAPE
            var result: Dictionary = {}
            result.shape = parse_mbs_dynamic(stream)
            result.density = stream.get_float()
            result.friction = stream.get_float()
            result.groupID = stream.get_32()
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.restitution = stream.get_float()
            result.sensor = stream.get_8() != 0
            return result

        20: #MBS_GAME
            var shapes_addr: int = stream.get_32()
            var atlases_addr: int = stream.get_32()
            var autotileFormats_addr: int = stream.get_32()
            var groups_addr: int = stream.get_32()
            var cgroups_addr: int = stream.get_32()
            var gameAttributes_addr: int = stream.get_32()

            var result: Dictionary = {}
            result.shapes = parse_mbs_inner(stream, shapes_addr, 4)
            result.atlases = parse_mbs_inner(stream, atlases_addr, 4)
            result.autotileFormats = parse_mbs_inner(stream, autotileFormats_addr, 4)
            result.groups = parse_mbs_inner(stream, groups_addr, 4)
            result.cgroups = parse_mbs_inner(stream, cgroups_addr, 4)
            result.gameAttributes = parse_mbs_inner(stream, gameAttributes_addr, 4)
            return result

        21: #MBS_ATLAS
            var result: Dictionary = {}
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            var members_addr: int = stream.get_32()
            result.allScenes = (stream.get_8() != 0)

            result.members = parse_mbs_inner(stream, members_addr, 4)
            return result

        22: #MBS_COLLISION_SHAPE
            var result: Dictionary = {}
            result.id = stream.get_32()
            var points_addr: int = stream.get_32()
            result.points = parse_mbs_inner(stream, points_addr, 4)
            return result

        24: #MBS_COLLISION_PAIR
            var result: Dictionary = {}
            result.group1 = stream.get_32()
            result.group2 = stream.get_32()
            return result

        25: #MBS_SCENE_HEADER
            var result: Dictionary = {}
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.description = cur_string_table[stream.get_32()]
            return result

        28: #MBS_SCENE
            var result: Dictionary = {}
            result.retainAtlases = stream.get_8() != 0
            result.depth = stream.get_32()
            result.description = cur_string_table[stream.get_32()]
            result.eventSnippetID = stream.get_32()
            result.extendedHeight = stream.get_32()
            result.extendedWidth = stream.get_32()
            result.extendedX = stream.get_32()
            result.extendedY = stream.get_32()
            result.format = cur_string_table[stream.get_32()]
            result.gravityX = stream.get_float()
            result.gravityY = stream.get_float()
            result.height = stream.get_32()
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.revision = cur_string_table[stream.get_32()]
            result.savecount = stream.get_32()
            result.tileDepth = stream.get_32()
            result.tileHeight = stream.get_32()
            result.tileWidth = stream.get_32()
            result.type = cur_string_table[stream.get_32()]
            result.width = stream.get_32()
            var actorInstances_addr: int = stream.get_32()
            var atlasMembers_addr: int = stream.get_32()
            var layers_addr: int = stream.get_32()
            var regions_addr: int = stream.get_32()
            var snippets_addr: int = stream.get_32()
            var terrain_addr: int = stream.get_32()
            var terrainRegions_addr: int = stream.get_32()

            result.actorInstances = parse_mbs_inner(stream, actorInstances_addr, 4)
            result.atlasMembers = parse_mbs_inner(stream, atlasMembers_addr, 4)
            result.layers = parse_mbs_inner(stream, layers_addr, 4)
            result.regions = parse_mbs_inner(stream, regions_addr, 4)
            result.snippets = parse_mbs_inner(stream, snippets_addr, 4)
            result.terrain = parse_mbs_inner(stream, terrain_addr, 4)
            result.terrainRegions = parse_mbs_inner(stream, terrainRegions_addr, 4)
            return result

        29: #MBS_ACTOR_INSTANCE
            var result: Dictionary = {}
            result.angle = stream.get_float()
            result.aid = stream.get_32()
            result.customized = stream.get_8() != 0
            result.groupID = stream.get_32()
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.scaleX = stream.get_float()
            result.scaleY = stream.get_float()
            result.x = stream.get_32()
            result.y = stream.get_32()
            result.z = stream.get_32()
            result.orderInLayer = stream.get_32()
            var snippets_addr: int = stream.get_32()

            result.snippets = parse_mbs_inner(stream, snippets_addr, 4)
            return result

        30: #MBS_COLOR_BACKGROUND
            var result: Dictionary = {}
            result.color = stream.get_32()
            return result

        31: #MBS_GRADIENT_BACKGROUND
            var result: Dictionary = {}
            result.color1 = stream.get_32()
            result.color2 = stream.get_32()
            return result

        33: #MBS_INTERACTIVE_LAYER
            var result: Dictionary = {}
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.order = stream.get_32()
            result.opacity = stream.get_32()
            result.blendmode = cur_string_table[stream.get_32()]
            result.scrollFactorX = stream.get_float()
            result.scrollFactorY = stream.get_float()
            result.visible = stream.get_8() != 0
            result.locked = stream.get_8() != 0
            result.color = stream.get_32()
            return result

        34: #MBS_IMAGE_BACKGROUND
            var result: Dictionary = {}
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.order = stream.get_32()
            result.opacity = stream.get_32()
            result.blendmode = cur_string_table[stream.get_32()]
            result.scrollFactorX = stream.get_float()
            result.scrollFactorY = stream.get_float()
            result.visible = stream.get_8() != 0
            result.locked = stream.get_8() != 0
            result.resourceID = stream.get_32()
            result.customScroll = stream.get_8() != 0
            return result

        39: #MBS_REGION
            var result: Dictionary = {}
            result.color = stream.get_32()
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.shape = parse_mbs_dynamic(stream)
            result.x = stream.get_32()
            result.y = stream.get_32()
            return result

        41: #MBS_POINT
            var result: Dictionary = {}
            result.x = stream.get_float()
            result.y = stream.get_float()
            return result

        44: #MBS_POLYGON
            var result: Dictionary = {}
            var points_addr: int = stream.get_32()
            result.points = parse_mbs_inner(stream, points_addr, 4)
            return result

        45: #MBS_POLY_REGION
            var result: Dictionary = {}
            var points_addr: int = stream.get_32()
            result.width = stream.get_32()
            result.height = stream.get_32()

            result.points = parse_mbs_inner(stream, points_addr, 4)
            return result

        47: #MBS_SNIPPET_DEF
            var result: Dictionary = {}
            result.attachedEvent = stream.get_8() != 0
            result.actorID = stream.get_32()
            result.classname = cur_string_table[stream.get_32()]
            result.description = cur_string_table[stream.get_32()]
            result.design = stream.get_8() != 0
            result.drawOrder = stream.get_32()
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.packageName = cur_string_table[stream.get_32()]
            result.sceneID = stream.get_32()
            result.type = cur_string_table[stream.get_32()]
            var attributes_addr: int = stream.get_32()
            var blocks_addr: int = stream.get_32()
            var events_addr: int = stream.get_32()

            result.attributes = parse_mbs_inner(stream, attributes_addr, 4)
            result.blocks = parse_mbs_inner(stream, blocks_addr, 4)
            result.events = parse_mbs_inner(stream, events_addr, 4)
            return result

        48: #MBS_ATTRIBUTE_DEF
            var result: Dictionary = {}
            result.type = stream.get_32()
            result.defaultValue = parse_mbs_dynamic(stream)
            result.description = cur_string_table[stream.get_32()]
            result.dropdown = cur_string_table[stream.get_32()]
            result.fullname = cur_string_table[stream.get_32()]
            result.hidden = stream.get_8() != 0
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.order = stream.get_32()
            return result

        49: #MBS_BLOCK
            var result: Dictionary = {}
            result.type = cur_string_table[stream.get_32()]
            result.id = stream.get_32()
            result.blockID = stream.get_32()
            return result

        50: #MBS_EVENT
            var result: Dictionary = {}
            result.displayName = cur_string_table[stream.get_32()]
            result.enabled = stream.get_8() != 0
            result.id = stream.get_32()
            result.name = cur_string_table[stream.get_32()]
            result.order = stream.get_32()
            result.repeats = stream.get_8() != 0
            return result

        51: #MBS_SNIPPET
            var result: Dictionary = {}
            result.enabled = stream.get_8() != 0
            result.id = stream.get_32()
            var properties_addr: int = stream.get_32()

            result.properties = parse_mbs_inner(stream, properties_addr, 4)
            return result

        52: #MBS_ATTRIBUTE
            var result: Dictionary = {}
            result.id = stream.get_32()
            result.type = cur_string_table[stream.get_32()]
            result.value = parse_mbs_dynamic(stream)
            return result

        53: #MBS_MAP_ELEMENT
            var result: Dictionary = {}
            result.key = cur_string_table[stream.get_32()]
            result.value = parse_mbs_dynamic(stream)
            return result

        _:
            assert(false, "Unsupported MBS type code " + str(type_code))

    return null

func parse_mbs(bytes: PackedByteArray) -> Variant:
    var stream: StreamPeerBuffer = StreamPeerBuffer.new()
    stream.data_array = bytes
    stream.big_endian = true
    var version: int = stream.get_32()
    var typeTableHash: int = stream.get_32()
    var typeTablePointer: int = stream.get_32()
    var stringTablePointer: int = stream.get_32()

    stream.seek(stringTablePointer)
    cur_string_table.clear()
    var string_table_size: int = stream.get_32()
    for i: int in range(0, string_table_size):
        var string_table_offset: int = stringTablePointer + 4 + i * 4
        stream.seek(string_table_offset)
        var string_offset: int = stream.get_32()
        stream.seek(string_offset)
        var string_length: int = stream.get_32()
        var string: String = stream.get_utf8_string(string_length)
        cur_string_table.push_back(string)

    # Root
    stream.seek(16)
    return parse_mbs_dynamic(stream)

func unpack(asset_details: Dictionary) -> PackedByteArray:
    if !data_pak_initialized:
        data_pak = FileAccess.get_file_as_bytes(pak_location)
        data_pak_initialized = true
    if !asset_details.has("length") or asset_details.length == 0:
        print(asset_details)
        return PackedByteArray()
    var sliced_bytes: PackedByteArray = data_pak.slice(asset_details.position, asset_details.position + asset_details.length)
    var decompressed_bytes: PackedByteArray = sliced_bytes.decompress_dynamic(-1, FileAccess.CompressionMode.COMPRESSION_GZIP)
    return decompressed_bytes

# This is incomplete as well, but sufficient for idleon parsing
func unserialize() -> Variant:
    var c: int = read_char()
    match c:
        82:
            var idx: int = read_digits()
            return scache[idx]

        97:
            var array: Array = []
            cache.push_back(array)
            while true:
                c = read_char(false)
                if c == 104:
                    pos += 1
                    break
                elif c == 117:
                    assert(false, "Unhandled 97 117")
                else:
                    array.push_back(unserialize())
            return array

        105:
            return read_digits()

        111:
            var obj: Dictionary = read_obj()
            cache.push_back(obj)
            return obj

        116:
            return true

        121:
            var length: int = read_digits()
            read_char()
            var string: String = data.substr(pos, length).uri_decode()
            pos += length
            scache.push_back(string)
            return string

        122:
            return 0

        _:
            assert(false, "Unhandled " + str(c))

    return null

func read_char(advance: bool = true) -> int:
    if pos >= data.length():
        assert(false, "Exceeded data length")
    var c: int = data.unicode_at(pos)
    if advance:
        pos += 1
    return c

func read_digits() -> int:
    var negative: bool = false
    var result: int = 0
    while true:
        var c: int = read_char()
        if c == 45:
            negative = true
        elif c < 48 or c > 57:
            pos -= 1
            break
        else:
            result = result * 10 + c - 48
    if negative:
        result *= -1
    return result

func read_obj() -> Dictionary:
    var result: Dictionary = {}
    while true:
        var c: int = read_char(false)
        if c == 103:
            pos += 1
            return result
        var key: Variant = unserialize()
        var value: Variant = unserialize()
        result[key] = value

    assert(false, "read_obj fail")
    return result

# MBS type code reference
#0 BOOLEAN
#1 INTEGER
#2 FLOAT
#3 STRING
#4 LIST
#5 DYNAMIC
#6 NULL
#7 MBS_HEADER
#8 MBS_TYPE_INFO
#9 MBS_FIELD_INFO
#10 MBS_RESOURCE
#11 MBS_BACKGROUND
#12 MBS_CUSTOM_BLOCK
#13 MBS_BLANK
#14 MBS_FONT
#15 MBS_MUSIC
#16 MBS_ACTOR_TYPE
#17 MBS_SPRITE
#18 MBS_ANIMATION
#19 MBS_ANIM_SHAPE
#20 MBS_GAME
#21 MBS_ATLAS
#22 MBS_COLLISION_SHAPE
#23 MBS_COLLISION_GROUP
#24 MBS_COLLISION_PAIR
#25 MBS_SCENE_HEADER
#26 MBS_TILESET
#27 MBS_TILE
#28 MBS_SCENE
#29 MBS_ACTOR_INSTANCE
#30 MBS_COLOR_BACKGROUND
#31 MBS_GRADIENT_BACKGROUND
#32 MBS_LAYER
#33 MBS_INTERACTIVE_LAYER
#34 MBS_IMAGE_BACKGROUND
#35 MBS_JOINT
#36 MBS_STICK_JOINT
#37 MBS_HINGE_JOINT
#38 MBS_SLIDING_JOINT
#39 MBS_REGION
#40 MBS_TERRAIN_REGION
#41 MBS_POINT
#42 MBS_SHAPE
#43 MBS_CIRCLE
#44 MBS_POLYGON
#45 MBS_POLY_REGION
#46 MBS_WIREFRAME
#47 MBS_SNIPPET_DEF
#48 MBS_ATTRIBUTE_DEF
#49 MBS_BLOCK
#50 MBS_EVENT
#51 MBS_SNIPPET
#52 MBS_ATTRIBUTE
#53 MBS_MAP_ELEMENT
#54 MBS_AUTOTILE_FORMAT
#55 MBS_CORNERS
