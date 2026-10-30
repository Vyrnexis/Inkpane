import std/os

import dbus
import glib

# System tray icon over D-Bus: StatusNotifierItem (the KDE/freedesktop tray protocol) plus a
# small com.canonical.dbusmenu context menu. SDL3's own tray loads GTK on Linux, so we
# speak the protocol directly.

const
  ItemPath = "/StatusNotifierItem"
  MenuPath = "/MenuBar"
  ItemInterface = "org.kde.StatusNotifierItem"
  MenuInterface = "com.canonical.dbusmenu"
  WatcherName = "org.kde.StatusNotifierWatcher"
  IdleIcon = "org.vyrnexis.Nimotate-tray"
  DrawingIcon = "org.vyrnexis.Nimotate-tray-active"

  MenuToggleId = 1'i32
  MenuSeparatorId = 2'i32
  MenuQuitId = 3'i32
  MenuIds = [MenuToggleId, MenuSeparatorId, MenuQuitId]

  ItemXml = """
<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="WindowId" type="i" access="read"/>
    <property name="IconThemePath" type="s" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="OverlayIconName" type="s" access="read"/>
    <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionIconName" type="s" access="read"/>
    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionMovieName" type="s" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    <signal name="NewTitle"/>
    <signal name="NewIcon"/>
    <signal name="NewAttentionIcon"/>
    <signal name="NewOverlayIcon"/>
    <signal name="NewToolTip"/>
    <signal name="NewStatus"><arg name="status" type="s"/></signal>
  </interface>
</node>"""

  MenuXml = """
<node>
  <interface name="com.canonical.dbusmenu">
    <property name="Version" type="u" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
    <method name="GetLayout">
      <arg name="parentId" type="i" direction="in"/>
      <arg name="recursionDepth" type="i" direction="in"/>
      <arg name="propertyNames" type="as" direction="in"/>
      <arg name="revision" type="u" direction="out"/>
      <arg name="layout" type="(ia{sv}av)" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg name="ids" type="ai" direction="in"/>
      <arg name="propertyNames" type="as" direction="in"/>
      <arg name="properties" type="a(ia{sv})" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg name="id" type="i" direction="in"/>
      <arg name="name" type="s" direction="in"/>
      <arg name="value" type="v" direction="out"/>
    </method>
    <method name="Event">
      <arg name="id" type="i" direction="in"/>
      <arg name="eventId" type="s" direction="in"/>
      <arg name="data" type="v" direction="in"/>
      <arg name="timestamp" type="u" direction="in"/>
    </method>
    <method name="EventGroup">
      <arg name="events" type="a(isvu)" direction="in"/>
      <arg name="idErrors" type="ai" direction="out"/>
    </method>
    <method name="AboutToShow">
      <arg name="id" type="i" direction="in"/>
      <arg name="needUpdate" type="b" direction="out"/>
    </method>
    <method name="AboutToShowGroup">
      <arg name="ids" type="ai" direction="in"/>
      <arg name="updatesNeeded" type="ai" direction="out"/>
      <arg name="idErrors" type="ai" direction="out"/>
    </method>
    <signal name="ItemsPropertiesUpdated">
      <arg name="updatedProps" type="a(ia{sv})"/>
      <arg name="removedProps" type="a(ias)"/>
    </signal>
    <signal name="LayoutUpdated">
      <arg name="revision" type="u"/>
      <arg name="parent" type="i"/>
    </signal>
  </interface>
</node>"""

type
  TrayAction* = enum
    TrayToggle
    TrayQuit

  Tray = object
    busName: string
    drawing: bool
    shortcutHint: string
    menuRevision: uint32
    actions: seq[TrayAction]

var tray: Tray

############################
# Variant Helpers
############################

proc emptyPixmaps(): GVariant =
  let builder = g_variant_builder_new(variantType("a(iiay)"))
  result = g_variant_builder_end(builder)
  g_variant_builder_unref(builder)

proc emptyArray(signature: static string): GVariant =
  let builder = g_variant_builder_new(variantType(signature))
  result = g_variant_builder_end(builder)
  g_variant_builder_unref(builder)

proc iconThemePath(): string =
  # Installed, icons sit in <prefix>/share/icons next to <prefix>/bin; run from the repo,
  # they are in data/icons next to bin/. The host also searches the normal icon theme paths.
  let prefix = getAppDir().parentDir()
  for path in [prefix / "share" / "icons", prefix / "data" / "icons"]:
    if dirExists(path): return path
  ""

proc tooltip(): GVariant =
  let shortcut = if tray.shortcutHint.len > 0: tray.shortcutHint & ", " else: ""
  let description =
    if tray.drawing: "Drawing — " & shortcut & "Esc or click to stop"
    else: "Click" & (if shortcut.len > 0: " or press " & tray.shortcutHint else: "") & " to draw"
  g_variant_new("(s@a(iiay)ss)", "".cstring, emptyPixmaps(), "Nimotate".cstring, description.cstring)

############################
# StatusNotifierItem
############################

proc itemProperty(name: string): GVariant =
  case name
  of "Category": g_variant_new_string("ApplicationStatus")
  of "Id": g_variant_new_string("nimotate")
  of "Title": g_variant_new_string("Nimotate")
  of "Status": g_variant_new_string("Active")
  of "WindowId": g_variant_new_int32(0)
  of "IconThemePath": g_variant_new_string(iconThemePath().cstring)
  of "OverlayIconName", "AttentionIconName", "AttentionMovieName": g_variant_new_string("")
  of "IconName": g_variant_new_string((if tray.drawing: DrawingIcon else: IdleIcon).cstring)
  of "IconPixmap", "OverlayIconPixmap", "AttentionIconPixmap": emptyPixmaps()
  of "ToolTip": tooltip()
  of "ItemIsMenu": g_variant_new_boolean(0)
  of "Menu": g_variant_new_object_path(MenuPath)
  else: nil

proc itemMethod(methodName: string, parameters: GVariant, invocation: pointer) =
  case methodName
  of "Activate", "SecondaryActivate":
    tray.actions.add(TrayToggle)
  else:
    discard   # ContextMenu/Scroll: the host shows our dbusmenu itself
  reply(invocation)

############################
# dbusmenu
############################

proc menuItemProperties(id: int32): GVariant =
  let props = g_variant_builder_new(variantType("a{sv}"))
  proc put(key: string, value: GVariant) =
    g_variant_builder_add(props, "{sv}", key.cstring, value)
  case id
  of MenuToggleId:
    put("label", g_variant_new_string((if tray.drawing: "Stop Drawing" else: "Start Drawing").cstring))
    put("icon-name", g_variant_new_string((if tray.drawing: "process-stop" else: "draw-freehand").cstring))
  of MenuSeparatorId:
    put("type", g_variant_new_string("separator"))
  of MenuQuitId:
    put("label", g_variant_new_string("Quit Nimotate"))
    put("icon-name", g_variant_new_string("application-exit"))
  else:
    discard
  result = g_variant_builder_end(props)
  g_variant_builder_unref(props)

proc menuItem(id: int32): GVariant =
  g_variant_new("(i@a{sv}@av)", id, menuItemProperties(id), emptyArray("av"))

proc menuLayout(parentId: int32): GVariant =
  if parentId != 0:
    return menuItem(parentId)
  let rootProps = g_variant_builder_new(variantType("a{sv}"))
  g_variant_builder_add(rootProps, "{sv}", "children-display".cstring, g_variant_new_string("submenu"))
  let children = g_variant_builder_new(variantType("av"))
  for id in MenuIds:
    g_variant_builder_add(children, "v", menuItem(id))
  result = g_variant_new("(i@a{sv}@av)", 0'i32, g_variant_builder_end(rootProps), g_variant_builder_end(children))
  g_variant_builder_unref(rootProps)
  g_variant_builder_unref(children)

proc menuProperty(name: string): GVariant =
  case name
  of "Version": g_variant_new_uint32(3)
  of "TextDirection": g_variant_new_string("ltr")
  of "Status": g_variant_new_string("normal")
  of "IconThemePath": emptyArray("as")
  else: nil

proc menuMethod(methodName: string, parameters: GVariant, invocation: pointer) =
  case methodName
  of "GetLayout":
    let parentValue = g_variant_get_child_value(parameters, 0)
    let parentId = g_variant_get_int32(parentValue)
    g_variant_unref(parentValue)
    reply(invocation, g_variant_new("(u@(ia{sv}av))", tray.menuRevision, menuLayout(parentId)))
  of "GetGroupProperties":
    let idsValue = g_variant_get_child_value(parameters, 0)
    var ids: seq[int32]
    for i in 0 ..< g_variant_n_children(idsValue).int:
      let idValue = g_variant_get_child_value(idsValue, csize_t(i))
      ids.add(g_variant_get_int32(idValue))
      g_variant_unref(idValue)
    g_variant_unref(idsValue)
    if ids.len == 0:
      ids = @MenuIds
    let items = g_variant_builder_new(variantType("a(ia{sv})"))
    for id in ids:
      g_variant_builder_add(items, "(i@a{sv})", id, menuItemProperties(id))
    reply(invocation, g_variant_new("(@a(ia{sv}))", g_variant_builder_end(items)))
    g_variant_builder_unref(items)
  of "GetProperty":
    reply(invocation, g_variant_new("(v)", g_variant_new_string("")))
  of "Event":
    var id: int32
    var eventId: cstring
    var data: GVariant
    var timestamp: uint32
    g_variant_get(parameters, "(i&s@vu)", addr id, addr eventId, addr data, addr timestamp)
    g_variant_unref(data)
    if $eventId == "clicked":
      case id
      of MenuToggleId: tray.actions.add(TrayToggle)
      of MenuQuitId: tray.actions.add(TrayQuit)
      else: discard
    reply(invocation)
  of "EventGroup":
    reply(invocation, g_variant_new("(@ai)", emptyArray("ai")))
  of "AboutToShow":
    reply(invocation, g_variant_new("(b)", cint(0)))
  of "AboutToShowGroup":
    reply(invocation, g_variant_new("(@ai@ai)", emptyArray("ai"), emptyArray("ai")))
  else:
    reply(invocation)

############################
# Registration
############################

proc registerWithWatcher() =
  try:
    g_variant_unref(call(WatcherName, "/StatusNotifierWatcher", WatcherName,
      "RegisterStatusNotifierItem", g_variant_new("(s)", tray.busName.cstring)))
  except DBusError:
    discard   # no tray host right now; we register again when one appears

proc onWatcherOwnerChanged(connection: GDBusConnection,
    senderName, objectPath, interfaceName, signalName: cstring,
    parameters: GVariant, userData: pointer) {.cdecl.} =
  # Plasma restarted (or a tray host started later): announce ourselves again.
  let newOwner = g_variant_get_child_value(parameters, 2)
  let hasOwner = g_variant_get_string(newOwner, nil)[0] != '\0'
  g_variant_unref(newOwner)
  if hasOwner:
    registerWithWatcher()

proc startTray*(busName, shortcutHint: string) =
  tray = Tray(busName: busName, shortcutHint: shortcutHint, menuRevision: 1)
  exportObject(ItemPath, ItemXml, ItemInterface, itemMethod, itemProperty)
  exportObject(MenuPath, MenuXml, MenuInterface, menuMethod, menuProperty)
  subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
    "/org/freedesktop/DBus", WatcherName, onWatcherOwnerChanged)
  registerWithWatcher()

proc setTrayDrawing*(drawing: bool) =
  if tray.drawing == drawing:
    return
  tray.drawing = drawing
  inc tray.menuRevision
  emitSignal(ItemPath, ItemInterface, "NewIcon")
  emitSignal(ItemPath, ItemInterface, "NewToolTip")
  emitSignal(MenuPath, MenuInterface, "LayoutUpdated", g_variant_new("(ui)", tray.menuRevision, 0'i32))

proc setTrayShortcutHint*(hint: string) =
  tray.shortcutHint = hint
  emitSignal(ItemPath, ItemInterface, "NewToolTip")

proc takeTrayActions*(): seq[TrayAction] =
  result = tray.actions
  tray.actions.setLen(0)
