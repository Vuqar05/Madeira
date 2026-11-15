# Steam Input milestone 5: iPad session script

One session for milestone 5 and milestone 4 item 3, starting with a short
regression check of milestones 1–4 (the rebuilt Dock has not run on a device
yet). The host and simulator checks already cover the logic; each step here
checks only what needs Valve's client, a real pad or the iPad. Note anything
unexpected with its step number; a step passes only when its **Expected**
happens as written. After the session, export the diagnostic log once
(Settings › Logs › Export): every step below leaves the lines needed to
diagnose it, so no step has to be repeated for logs.

**Have ready**

- The Debug build named in the session message (never a Release build).
- The paired DualSense, charged, and the on-screen controls set up for Terraria.
- Terraria (App 105600; its game default is a Steam Deck layout) and Portal 2
  (App 620; rumble, a bundled game default). Both installed, Controller set to
  Steam Input in Game details › Controls.
- Internet. About 60–75 minutes.

Steps are grouped per game. Unless a step says otherwise the Xbox switch
(`env.MADEIRA_STEAM_INPUT_XBOX`) is off, which is the default.

## A. Regression of milestones 1–4

**Portal 2**

1. *(M1, M2)* Start Portal 2 with the DualSense on. Open the session menu.
   **Expected:** the game starts; the Steam Input status line reads "Active: Game
   default." and "Steam sees a DualSense in this session."; the pad moves in the menu.
2. *(M3)* Session menu › Community and personal layouts › pick any community
   layout › Apply this revision (confirm if asked). **Expected:** "Active: Community
   layout." and the pad still works with the new bindings.
3. *(M3)* Session menu › Use game default. **Expected:** "Active: Game default."
   within a few seconds; no button stays pressed.

**Terraria**

4. *(M4)* Start Terraria. Community and personal layouts › Personal layouts ›
   New layout › Start from a Steam template › Gamepad. Edit it: Face buttons ›
   Cross (A) to B (Circle); Save; Apply this personal layout. **Expected:** "Active:
   Personal layout."; Cross acts as Circle in the game.
5. *(M4)* Quit the game and Madeira; start Terraria again. **Expected:** the same
   personal layout is re-applied without any question; Cross still acts as Circle.

## B. Milestone 5 with the DualSense (Terraria)

6. *(M5 item 2, M4 item 3)* With Terraria running: Personal layouts › New layout ›
   Start from the game default. Open it, Edit layout, change one easy-to-see
   binding (for example Cross to Triangle), Save, then Apply this personal layout….
   **Expected:** before anything applies, an alert "Made for another controller"
   lists what your DualSense cannot supply (it names a Steam Deck and, for
   example, rear buttons or overlay menus) and says Valve's engine maps what it
   can.
7. *(M5 item 2)* Tap Cancel. **Expected:** nothing changes; the status line still
   shows the previous layout.
8. *(M5 item 2, M4 item 3)* Apply it again and tap Apply anyway. **Expected:**
   "Active: Personal layout."; your changed binding works in the game.
9. *(M5 item 2, M4 item 3)* Quit the game and Madeira; start Terraria again.
   **Expected:** the layout is re-applied without asking again; the changed
   binding still works.
10. *(M5 item 2)* Session menu › Use game default. **Expected:** the same alert
    appears for Terraria's Steam Deck default; after Apply anyway the status reads
    "Active: Game default."
11. *(M5 item 7: gyro, touchpad)* Edit the personal layout from step 6: set Gyro to
    a mouse or camera mode and the touchpad (left or right trackpad) to a mouse
    mode; Save and apply. **Expected:** no alert about gyro or trackpads (only the
    Steam Deck items, already confirmed for the old revision, are asked again
    because the revision changed); tilting the DualSense and sliding on its
    touchpad move the in-game cursor or camera smoothly.
12. *(M5 item 7: overlay menus)* Edit the same layout: give one input a Radial
    menu (or Touch menu) with two entries; Save and apply; use it in the game.
    **Expected:** record what happens: the menu appears and its entries work, or
    nothing appears. (Either answer is evidence; overlay menus stay listed as
    unsupported until it is "appears".)
13. *(M5 item 7: keyboard/mouse, mixed)* Apply a layout that mixes gamepad buttons
    with a keyboard key and mouse movement (Steam template "Gamepad with Mouse
    Trackpad" or a community layout that does). **Expected:** the key and the mouse
    reach the game together with the gamepad buttons.
14. *(M5 item 5: held input)* Hold Cross and, while holding it, apply another
    layout from the session menu. Release, then press Cross again. **Expected:** no
    input sticks; Cross works under the new layout only after you pressed it again.
15. *(M5 item 5: rapid changes)* Switch layouts three times quickly (Game default,
    personal, Game default). **Expected:** the last choice ends up active; no
    stuck buttons; no duplicate controller in the game.
16. *(M5 item 5: background)* Hold a stick, press the Home gesture to leave Madeira
    for 10 s, return. **Expected:** the character stopped while away; the pad works
    after returning.
17. *(M5 item 5: unplug and late connect)* Turn the DualSense off (hold PS) in the
    game for 10 s, then turn it on. **Expected:** nothing moves while it is off; it
    works again after reconnecting, with the same layout.

**Portal 2**

18. *(M5 item 7: rumble)* Start Portal 2 and do something that rumbles (e.g. take
    damage or fire). **Expected:** the DualSense rumbles. Quit the game while it
    rumbles if you can. **Expected:** the rumble stops when the session ends.

## C. Game details while no game runs

19. *(M5 item 4)* Close the session. Open Terraria › Game details › Controls.
    **Expected:** the status line reads "Chosen: …. It is applied when the game
    starts." and "Steam sees a DualSense …".
20. *(M5 item 4)* Tap "Use the game default from the next launch". **Expected:** the
    line changes to "Chosen: Game default (Steam's saved layout for this game).";
    starting Terraria then shows Game default.

## D. On-screen controls as an Xbox controller (Terraria)

21. *(M5 item 1)* Settings › All settings › "Steam Input: Xbox identity for
    on-screen and other pads" → 1. Turn the DualSense off. Start Terraria and use
    the on-screen controls. **Expected:** the session menu says "Steam sees an Xbox
    controller in this session."; the on-screen buttons and sticks move the game;
    the game shows Xbox button glyphs where it shows any. If the controls do
    nothing, note it: the switch is the fallback and step 22 still applies.
22. *(M5 item 1, item 2)* Community and personal layouts. **Expected:** the filter
    reads "Xbox controller layouts only"; applying the DualSense personal layout
    from step 6 asks for confirmation (made for a DualSense/Steam Deck).
23. *(M5 item 1)* Quit; turn the DualSense on; start Terraria again (switch still on).
    **Expected:** "Steam sees a DualSense"; the layout from step 9 is active again.
    Then set the switch back to 0.

## E. Recovery after Madeira is killed mid-game (Terraria)

24. *(M5 item 3)* Start Terraria. While the game runs, swipe Madeira away in the
    app switcher. Reopen Madeira and start Terraria. **Expected:** the game starts
    normally; if it stays at "Loading Steam…", after 2 minutes the screen says
    "Steam has not connected yet…". Note which, and how long the start took.
25. *(M5 item 3)* Only if step 24 stalled: close the session, start once more.
    **Expected:** note whether the second start works.

## F. Without keyboard-and-mouse mode

26. *(M5 item 9)* Settings › All settings › `env.MADEIRA_PAD_KBM` → 0. Restart
    Madeira; Terraria › Game details › Controls. **Expected:** Controller still
    offers Steam Input (and not Keyboard and mouse); starting Terraria uses Steam
    Input as before. Set it back to 1.

Waived by the owner (2026-11-15): physical multi-pad play and iPad
suspend/resume; both are covered by host checks.
