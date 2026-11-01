import draw/scene

# The tour (`inkpane --tour` or the tray menu): on the whiteboard, one step at a time, each
# naming a key and what to do with it. A step is done when the drawing shows it was done,
# so the user learns by pressing the keys; → skips a step, ← goes back.

type
  TourView* = object
    ## What the tour watches, as the app is after an event.
    counts*: array[Tool, int]   # finished items of each kind, on every monitor
    items*: int
    filled*: int
    color*: int                 # index into the palette
    width*: float32
    board*: int                 # 0 the desktop, 1 the whiteboard, 2 the blackboard
    undos*: int                 # Ctrl+Z presses that undid something
    screenshots*: int
    closes*: int
    open*: bool
    toolbar*: bool              # shown (Tab hides it)

  Check = enum
    Drawn, DrawnFilled, Recoloured, Resized, Erased, Undone, Cleared, OnBoard,
    ToolbarHidden, ToolbarShown, Saved, Reopened, Never

  Step = object
    text: string
    check: Check
    tool: Tool      # for Drawn
    board: int      # for OnBoard

  Tour* = object
    active*: bool
    step: int
    start: TourView   # the view when this step began

const Steps = [
  Step(text: "R  Rectangle: drag a box", check: Drawn, tool: Rectangle),
  Step(text: "D  Diamond: drag one. Hold Shift to keep it even", check: Drawn, tool: Diamond),
  Step(text: "O  Ellipse: drag one. Hold Ctrl to draw it from the centre", check: Drawn,
    tool: Ellipse),
  Step(text: "A  Arrow: drag from one shape to another", check: Drawn, tool: Arrow),
  Step(text: "L  Line: drag one. Hold Shift to snap to 15°", check: Drawn, tool: Line),
  Step(text: "P  Pen: draw freehand, a tick or your name", check: Drawn, tool: Pen),
  Step(text: "T  Text: click, type a label, Enter to finish", check: Drawn, tool: Text),
  Step(text: "N  Step marker: click to place 1, 2, 3", check: Drawn, tool: Marker),
  Step(text: "Shift+1 … Shift+8  Colour: pick another", check: Recoloured),
  Step(text: "-  +  Width: thinner or thicker (the mouse wheel works too)", check: Resized),
  Step(text: "F  Fill: turn it on, then drag a rectangle or an ellipse", check: DrawnFilled),
  Step(text: "H  Highlighter: drag over something to mark it", check: Drawn, tool: Highlighter),
  Step(text: "Right-drag  Erase: rub something out (or E for the eraser)", check: Erased),
  Step(text: "Ctrl+Z  Undo: bring it back", check: Undone),
  Step(text: "C  Clear: wipe everything", check: Cleared),
  Step(text: "Ctrl+Z  Undo works for clearing too", check: Undone),
  Step(text: "Ctrl+B  Blackboard", check: OnBoard, board: 2),
  Step(text: "Ctrl+W  Back to the whiteboard", check: OnBoard, board: 1),
  Step(text: "Tab  Hide the toolbar: the keys still work", check: ToolbarHidden),
  Step(text: "Tab  Bring it back. Drag it by the dots at its left end to move it",
    check: ToolbarShown),
  Step(text: "Ctrl+S  Screenshot: press it, then click to save your drawing", check: Saved),
  Step(text: "Esc  Close Inkpane, then open it again with Meta+Z or the tray icon",
    check: Reopened),
  Step(text: "Ctrl+Z  Your drawing is back: even closing can be undone", check: Undone),
  Step(text: "All done! F1 lists every key, and 1 / V lets you click apps under your " &
    "drawing.  Esc ends the tour", check: Never)]

proc done(step: Step, start, now: TourView): bool =
  case step.check
  of Drawn: now.counts[step.tool] > start.counts[step.tool]
  of DrawnFilled: now.filled > start.filled
  of Recoloured: now.color != start.color
  of Resized: now.width != start.width
  of Erased: now.items < start.items
  of Undone: now.undos > start.undos and now.items > 0
  of Cleared: now.items == 0
  of OnBoard: now.board == step.board
  of ToolbarHidden: not now.toolbar
  of ToolbarShown: now.toolbar
  of Saved: now.screenshots > start.screenshots
  of Reopened: now.open and now.closes > start.closes
  of Never: false

proc begin*(tour: var Tour, now: TourView) =
  tour = Tour(active: true, start: now)

proc update*(tour: var Tour, now: TourView): bool =
  ## Moves on when the current step is done; true when the hint changed.
  if tour.active and Steps[tour.step].done(tour.start, now):
    tour.step = min(tour.step + 1, Steps.high)
    tour.start = now
    return true

proc skip*(tour: var Tour, by: int, now: TourView) =
  ## → and ←: the next or previous step, watched from now on.
  tour.step = clamp(tour.step + by, 0, Steps.high)
  tour.start = now

proc keepsOnClose*(tour: Tour): bool =
  ## Closing ends the tour, except at the step that asks for it.
  tour.active and Steps[tour.step].check == Reopened

proc hint*(tour: Tour): string =
  result = $(tour.step + 1) & " / " & $Steps.len & "     " & Steps[tour.step].text
  if tour.step < Steps.high:
    result.add("        →  skip")
