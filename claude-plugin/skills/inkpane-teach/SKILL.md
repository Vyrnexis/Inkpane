---
name: inkpane-teach
description: Teach, guide or explain visually on the user's real screen with Inkpane - circle the control to click, add arrows and short labels, number the steps, sketch diagrams on a whiteboard, and take screenshots to check the user's progress. Use when the user asks how to do something in an app on their computer, wants a walkthrough, asks "where is…", or when an explanation (a data flow, an architecture, how something works) would be clearer drawn. Needs the inkpane MCP tools.
---

# Teaching on the user's screen with Inkpane

Inkpane draws on top of everything on the user's screen. You point; **the user does
every click and keystroke themselves**. That is the point: people learn by doing, and
you cannot change anything on their system through Inkpane.

## Before you start

- **Ask once before the first screenshot** in a session ("May I look at your screen to
  show you where things are?"), unless the user already said screenshots are fine or
  asked you to look. A screenshot sends the user's screen to you. If they say no,
  explain in words, or draw on the whiteboard instead.
- Say so in one short line whenever you take a screenshot ("Taking a look…").
- Call `screen_info` once if there could be several monitors. Use the monitor the app
  is on; ask if you can't tell.

## The step loop

Never draw a whole procedure at once. For each step:

1. **Look**: `screenshot`. Coordinates are that image's pixels, origin top-left.
2. **Point at one thing** (see "Marks" below): usually one circle or arrow plus a label
   of 2–4 words, or a step marker.
3. **Explain in chat**, briefly: what to do and *why*. The screen shows *where*; the
   chat says *why*. Never put explanations on screen.
4. **Wait**: end your turn and ask the user to say "done" (or describe what happened)
   when they've done it.
5. **Check**: `screenshot` again. If it worked, `clear` and go to the next step. If not,
   see "When something goes wrong".

When the task is done: `clear`, sum up in a sentence or two, and offer to repeat any step.

## Marks

- **Circle a control**: `circle` with the control's own box `[left, top, right,
  bottom]`, read off the screenshot. Inkpane makes the ellipse big enough to frame it
  (an ellipse drawn on the control's own corners would cut through them). Give it a
  `label` and a `label_side` and the label is placed just outside the circle: pick the
  side where the screenshot shows **empty space** (a window margin, blank panel area, the
  desktop), never a side with buttons, list rows or text. Prefer this; it is the most
  forgiving mark.
- **Arrow**: from empty space towards the target; the head (second point) stops just
  short of the edge of what it points at. Use it when the target is small or crowded.
- **Label**: `add_text` placed in empty space next to the mark, never over the thing
  being marked or over text the user has to read. 2–4 words: "Click here", "Your
  Wi-Fi name", "Not this one". `x`, `y` is the label's top-left corner. Leave a gap of
  about 10 px from the circle; on a busy screen (lists, toolbars) put it beside the
  circle in an empty margin rather than under it, or point to it with a short arrow
  from a label in empty space.
- **Step markers** (`add_step_marker`) number things in order: 1, 2, 3. Use them to
  show the order of several clicks the user should do in one go, or to label parts of a
  screen while you explain them in chat ("1 is the search box, 2 …").
- **Highlighter**: a straight bar over one line of text ("read this line"). Use yellow.
- **Rectangle**: a whole region ("everything in this panel").
- **At most about three marks on screen.** Clear before the next step; `undo_last`
  removes just your latest mark.

### Colours (keep them consistent)

- **green**: do this / the right place
- **blue**: look here / information
- **orange** or **yellow** (highlighter): attention to a line of text
- **red**: a mistake, or "not this one". Nothing else.

On a light window, all of these show well; on very dark or very bright areas Inkpane adds
contrast to text automatically.

### Accuracy

Your coordinates come from your reading of the screenshot, which can be a few pixels
off. So:

- Prefer **generous circles** to precise underlines.
- For a small target in a crowded area, combine an arrow with a label naming it
  ("the gear icon").
- After drawing anything important, take a screenshot and look: if the mark is off,
  `undo_last` and draw it again. Don't apologise at length; just fix it.

## Whiteboard explanations

For ideas no app shows (how data flows, what a git branch is, how DNS resolves a name),
`set_board` to `"whiteboard"` and draw the diagram **in the order you explain it**:

- Boxes (`rectangle`) for things, with their name as the `label` (Inkpane centres it;
  use `label_color: "black"` on the whiteboard), and `arrow` for flows.
- Label an arrow with `add_text` beside its middle, clear of the line: above a level
  arrow, to the side of a steep one. When two arrows run in opposite directions, keep
  them 40+ px apart so each has room for its label.
- Lay it out left to right or top to bottom, with plenty of space: boxes of about
  200 × 80 px, 150+ px apart. Default text (16 px) fits about 15 characters in a
  200 px box.
- Draw a part, explain it in chat, then draw the next, so the user follows along.
- Use `diamond` for decisions, `ellipse` for start/end.
- `set_board` to `"none"` when done, to bring the desktop back (the drawing stays).

The whiteboard needs no screenshots, so it works even if the user declined them.

## When something goes wrong

- **The user clicked the wrong thing**: screenshot, circle the right control in green,
  and if useful mark the wrong one in red with "not this". Explain the difference in
  one sentence.
- **The screen changed** (a dialog opened, the window moved): your old marks are now in
  the wrong place: `clear`, screenshot, and mark again.
- **A tool returns an error** (Inkpane not running, no permission for screenshots): tell
  the user plainly what it says. The first screenshot may show a desktop dialog asking
  to allow Inkpane to take screenshots; ask the user to allow it.

## Things to avoid

- Drawing every step at once, or more than ~3 marks.
- Long text on screen. Labels are short; explanations go in chat.
- Marks covering the thing they point at, or covering text the user must read.
- Taking screenshots without saying so, or when not teaching.
- `close`: it also wipes the user's own drawing. Only when the user says they're done.
- `clear` with `scope: "all"` unless the user asks: it removes their drawing too.
