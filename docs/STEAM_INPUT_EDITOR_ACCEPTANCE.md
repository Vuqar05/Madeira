# Steam Input editor: iPad acceptance script

Milestone 4 items 1, 3, 4, 6, 7 and 8 (see `STEAM_INPUT_INTEGRATION_PLAN.md`).
The host and simulator checks already cover the editing operations, byte
preservation, revisions, drafts, deletion refusals, recovery and the live-edit
journal and receipts. This script covers only what they cannot establish:
Valve's engine running an edited layout on the iPad, a real pad during a live
switch, and the iPad's own file picker, share sheet and SwiftUI behaviour.

Use the Debug build from this branch, a paired DualSense or DualShock, and a
native Steam Input game you have already used with a personal layout. Note
anything unexpected with the step number. A step passes only when everything in
it happens as written.

1. **Create and edit.**
   1. Open the game's Steam Input controls, then Community layouts › Personal
      layouts · local › New layout….
   2. Start from the game default. If Madeira has not seen this game running
      with the controller since installing this build, it says so: start the
      game once, quit it, and try again from the menu. Then repeat New layout and start from the
      Gamepad template. Both appear in the list.
   3. Open the template layout, then Edit layout › Face buttons › Edit face
      buttons.
   4. Change Cross (A) to B (Circle), then tap Save.

   Expected: Save becomes disabled and Revision history shows 2.
2. **Use it in the game.**
   1. Start the game and apply the edited layout from its page.
   2. Wait for "Active personal layout".
   3. Press Cross.

   Expected: the game sees B. The other buttons behave as before.
3. **Restart.** Quit the game and Madeira, then start the game again. Expected:
   the same layout is reapplied and Cross still gives B.
4. **Live edit while held.**
   1. With the game running, open Edit layout and change Cross to Y (Triangle).
   2. Hold Cross and tap Save and apply now.
   3. Release Cross, then press it again.

   Expected: no input sticks after release. The status confirms the change, and
   Cross now gives Y.
5. **A live edit that is refused.**
   1. With the game running, set Gyro to Gyro to Joystick Camera in the editor.
   2. Tap Save and apply now.

   Expected: the editor says "Unavailable inputs or features: gyro." and that
   the layout in use is unchanged. Cross still gives Y, and nothing was released
   or switched. Set Gyro back to Not used. The edits stayed as unsaved changes
   throughout.
6. **Switches.**
   1. Add an action set copied from Default and bind a button to Change action
      set for it.
   2. Add a layer, bind a button to Hold layer, and give the layer one different
      binding.
   3. Add a mode shift on a button for the right stick.
   4. Save and apply, then use each switch in the game.

   Expected: each switch does what it shows. Report any that does nothing: the
   written `CHANGE_PRESET n 1 1` and `hold_layer n 0 0` forms and mode shifts
   are verified only against layout files, not on the device.
7. **Toggle, turbo and settings.**
   1. Turn on Toggle for one button and Turbo for another.
   2. Set the right stick's outer dead zone or response curve to a clearly
      different value.
   3. Save and apply.

   Expected: each change is noticeable in the game.
8. **Unknown fields and the community original.**
   1. Edit a personal copy of a community layout and save.
   2. Export it and import the exported file.

   Expected: the community layout's own page still shows its original revision
   unchanged, and the imported copy behaves like the edited one. The editor's
   "Kept unchanged · not editable yet" list is the same before and after.
9. **iPad presentation.**
   1. Import a VDF file from Files, then cancel a second import.
   2. Rename, duplicate and delete a layout that is not in use.
   3. Try to delete the layout that is in use.

   Expected: the picker opens and closes each time, and deleting the layout in
   use is refused with "This layout is this game's chosen Steam Input layout. …".
   Export opens the share sheet.
10. **Unsaved edits after Madeira is closed.**
    1. Make an edit without saving.
    2. Swipe Madeira away and reopen the layout's editor.

    Expected: "Restore unsaved edits" brings the edit back. Discard leaves the
    saved revision.

Not part of this script: gyro, touchpad, overlay menus, rear buttons and
keyboard/mouse delivery to the game (milestone 5). They can be edited, and a
layout that needs them is refused at apply with the reason.
