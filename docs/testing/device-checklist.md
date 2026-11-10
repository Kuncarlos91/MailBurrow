# Device testing checklist

[Main index](../../README.md) · [Project status](status.md) · [Troubleshooting](../troubleshooting/README.md)

Use harmless synthetic messages/files and report Pass/Fail/Not tested with model, OS, source/build. Never report private hosts, keys or real mail.

1. Connect to your configured HTTPS server; restart and confirm secure connection/account restoration. Invalid/revoked keys and invalid TLS fail safely.
2. Browse folders, search, clear search, apply filters/date selection and page newer/older/go-to-page. Verify progress, empty states and list scrolling.
3. Switch authorized accounts during a delayed search; no old-account messages/folders appear after the switch. Restart restores the choice.
4. Open a long/complex message and Back. Check date, scrolling, remote-resource blocking, link cancel/confirmation and safe errors/retry.
5. Save a harmless attachment. Cancel download and retry. Open/cancel chooser/reopen; open viewer/close/reopen without re-saving. Repeat local and cloud providers. Cancel a replacement save; previous reference remains. Leaving the reader ends the handle; use Files or save again.
6. Lose the private-network connection during mail/search/attachment work. All relevant refresh/retry paths show progress/error and recover after reconnecting. Old errors must not remain after successful revalidation.
7. Largest text, landscape, navigation bars/notches, keyboard, iPad split view, light/dark mode, screen-reader labels and reachable controls.
8. Demo mode: tap Try the demo with no network connected. Browse, search, filter, switch the three accounts, open the long and complex messages, and save and open an attachment. The banner shows on every screen, including Connection settings and the reader, and at the largest text it stays a compact bar. Exit from the banner, from Settings and from the reader; a previously saved real connection still restores. Relaunching never opens the demo.
9. Before public binaries also verify signed update, OS restart, missing viewer/deleted copy, low storage, real transport cancellation/timeouts, startup/memory and exact artifact metadata/notices. Host mocks do not establish these results.
