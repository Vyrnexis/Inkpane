import std/[os, strutils, unicode]

import dbus
import glib
import portal

# Pointer and keyboard input through the desktop's RemoteDesktop portal, for inkpane-mcp
# when the user has allowed AI clicking. The desktop asks the user for every session (one
# per inkpane-mcp process, so per AI conversation) and nothing is remembered: an AI that
# edits the settings file still can't click until a person answers that dialog.
# Absolute pointer positions need a screen-cast stream per monitor, so the session also
# selects the monitors; nothing ever reads those streams.

const
  PortalBusName = "org.freedesktop.portal.Desktop"
  PortalObjectPath = "/org/freedesktop/portal/desktop"
  RemoteInterface = "org.freedesktop.portal.RemoteDesktop"
  CastInterface = "org.freedesktop.portal.ScreenCast"
  StartTimeoutSeconds = 120   # the user may be reading the permission dialog
  KeyboardAndPointer = 3'u32
  Monitors = 1'u32

  ButtonCodes* = [("left", 0x110'i32), ("right", 0x111'i32), ("middle", 0x112'i32)]   # evdev

type
  CastStream* = object
    node*: uint32
    x*, y*, w*, h*: int   # the monitor it shows, in logical px

  RemoteSession* = ref object
    handle: string
    streams*: seq[CastStream]

proc lookupPair(dict: GVariant, key: string): (int, int) =
  let value = g_variant_lookup_value(dict, key.cstring, variantType("(ii)"))
  if value.isNil:
    return
  var a, b: int32
  g_variant_get(value, "(ii)", addr a, addr b)
  g_variant_unref(value)
  (int(a), int(b))

proc close*(session: RemoteSession) =
  try:
    g_variant_unref(call(PortalBusName, session.handle, "org.freedesktop.portal.Session", "Close"))
  except DBusError:
    discard

proc start*(): RemoteSession =
  ## Asks the desktop for pointer and keyboard control of every monitor; may show its
  ## permission dialog. Raises PortalError when refused.
  let created = portalRequest(RemoteInterface, "CreateSession", StartTimeoutSeconds,
    proc(token: string): GVariant =
      let options = newOptions(token)
      options.addString("session_handle_token", newToken())
      g_variant_new("(@a{sv})", options.finish()))
  let handleValue = g_variant_lookup_value(created, "session_handle", variantType("s"))
  g_variant_unref(created)
  if handleValue.isNil:
    raise newException(PortalError, "The desktop portal did not return a session.")
  result = RemoteSession(handle: $g_variant_get_string(handleValue, nil))
  g_variant_unref(handleValue)
  let handle = result.handle
  try:
    g_variant_unref(portalRequest(RemoteInterface, "SelectDevices", StartTimeoutSeconds,
      proc(token: string): GVariant =
        let options = newOptions(token)
        g_variant_builder_add(options, "{sv}", "types".cstring, g_variant_new_uint32(KeyboardAndPointer))
        g_variant_new("(o@a{sv})", handle.cstring, options.finish())))
    g_variant_unref(portalRequest(CastInterface, "SelectSources", StartTimeoutSeconds,
      proc(token: string): GVariant =
        let options = newOptions(token)
        g_variant_builder_add(options, "{sv}", "types".cstring, g_variant_new_uint32(Monitors))
        g_variant_builder_add(options, "{sv}", "multiple".cstring, g_variant_new_boolean(1))
        g_variant_new("(o@a{sv})", handle.cstring, options.finish())))
    let started = portalRequest(RemoteInterface, "Start", StartTimeoutSeconds,
      proc(token: string): GVariant =
        g_variant_new("(os@a{sv})", handle.cstring, "".cstring, newOptions(token).finish()))
    defer: g_variant_unref(started)
    let streams = g_variant_lookup_value(started, "streams", variantType("a(ua{sv})"))
    if not streams.isNil:
      for i in 0 ..< g_variant_n_children(streams):
        let stream = g_variant_get_child_value(streams, i)
        let node = g_variant_get_child_value(stream, 0)
        let props = g_variant_get_child_value(stream, 1)
        let (x, y) = props.lookupPair("position")
        let (w, h) = props.lookupPair("size")
        result.streams.add(CastStream(node: g_variant_get_uint32(node), x: x, y: y, w: w, h: h))
        for part in [node, props, stream]:
          g_variant_unref(part)
      g_variant_unref(streams)
    if result.streams.len == 0:
      raise newException(PortalError, "The desktop shared no monitor, so pointer positions can't be given.")
  except CatchableError:
    result.close()
    raise

############################
# Input
############################

proc notify(session: RemoteSession, methodName: string, parameters: GVariant) =
  g_variant_unref(call(PortalBusName, PortalObjectPath, RemoteInterface, methodName, parameters))

proc moveTo*(session: RemoteSession, stream: CastStream, x, y: float) =
  ## x, y in logical px of the stream's monitor.
  session.notify("NotifyPointerMotionAbsolute", g_variant_new("(oa{sv}udd)",
    session.handle.cstring, pointer(nil), stream.node, cdouble(x), cdouble(y)))

proc button*(session: RemoteSession, code: int32, down: bool) =
  session.notify("NotifyPointerButton", g_variant_new("(oa{sv}iu)", session.handle.cstring,
    pointer(nil), code, uint32(ord(down))))

proc scroll*(session: RemoteSession, steps: int) =
  ## Mouse-wheel notches; positive scrolls down.
  session.notify("NotifyPointerAxisDiscrete", g_variant_new("(oa{sv}ui)", session.handle.cstring,
    pointer(nil), 0'u32, int32(steps)))

proc keycode*(session: RemoteSession, code: int, down: bool) =
  ## A physical key by its evdev code: no keysym emulation, so modifiers land in order.
  session.notify("NotifyKeyboardKeycode", g_variant_new("(oa{sv}iu)", session.handle.cstring,
    pointer(nil), int32(code), uint32(ord(down))))

const
  EvdevKeys = [
    ("ctrl", 29), ("shift", 42), ("alt", 56), ("super", 125), ("meta", 125),
    ("enter", 28), ("return", 28), ("tab", 15), ("esc", 1), ("escape", 1),
    ("backspace", 14), ("delete", 111), ("insert", 110), ("space", 57), ("up", 103), ("down", 108),
    ("left", 105), ("right", 106), ("home", 102), ("end", 107), ("pageup", 104),
    ("pagedown", 109), ("f11", 87), ("f12", 88)]
  LetterCodes = [30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31,
                 20, 22, 47, 17, 45, 21, 44]   # a .. z, by their place on a US keyboard

proc evdevCode*(name: string): int =
  ## A key name ("ctrl", "enter", "f5", "s", "7") to its evdev code; -1 when unknown.
  ## Letters are by position, so shortcuts follow QWERTY-like layouts.
  let lower = name.toLowerAscii
  for (n, code) in EvdevKeys:
    if lower == n:
      return code
  if lower.len >= 2 and lower[0] == 'f' and lower[1 .. ^1].allCharsInSet(Digits):
    let n = parseInt(lower[1 .. ^1])
    if n in 1 .. 10:
      return 58 + n
  if lower.len == 1:
    case lower[0]
    of 'a' .. 'z': return LetterCodes[ord(lower[0]) - ord('a')]
    of '1' .. '9': return ord(lower[0]) - ord('1') + 2
    of '0': return 11
    else: discard
  -1

proc key(session: RemoteSession, keysym: int, down: bool) =
  session.notify("NotifyKeyboardKeysym", g_variant_new("(oa{sv}iu)", session.handle.cstring,
    pointer(nil), int32(keysym), uint32(ord(down))))

proc keysymFor(rune: Rune): int =
  ## Latin-1 characters are their own keysym; others are 0x1000000 + the code point.
  case int(rune)
  of 0x0a: 0xff0d   # newline: Return
  of 0x09: 0xff09
  of 0x20 .. 0x7e, 0xa0 .. 0xff: int(rune)
  else: 0x01000000 + int(rune)

proc typeRune*(session: RemoteSession, rune: Rune) =
  ## One character as a keysym: the fallback when text can't be pasted. KWin applies the
  ## Shift a keysym needs to the next key ("Hello, you!" came out as "hELLO< YOU1"), so
  ## capitals are typed as our own Shift + the small letter and Shift is let go after
  ## every character. Letters, digits and spaces come out right; symbols that need Shift
  ## may not.
  const ShiftL = 0xffe1
  const GapMs = 15
  let upper = int(rune) in ord('A') .. ord('Z')
  let sym = if upper: int(rune) + 32 else: keysymFor(rune)
  if upper:
    session.key(ShiftL, true)
    sleep(GapMs)
  session.key(sym, true)
  sleep(GapMs)
  session.key(sym, false)
  sleep(GapMs)
  session.key(ShiftL, false)
  sleep(GapMs)
