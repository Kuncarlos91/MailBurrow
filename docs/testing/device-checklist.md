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
9. App lock (versions after 0.5.0): turn it on (biometric, and device PIN/pattern/passcode fallback); change the timing; Home and return for immediately and for the 1-minute grace (short and long away); cancel the prompt (stays locked, no automatic re-prompt); recent-apps preview blank; swipe away and reopen (locked); save an attachment within the grace period; turn it off (cancel keeps it on). On iOS also check Face ID and the app-switcher snapshot.
10. Own certificate (0.6.0 and later), with fictional lab certificates only:
    - Connect to a private-CA server: it fails, then **Use your own certificate** offers the flow. Pick the root, compare the fingerprint, **Trust and connect**.
    - Restart, switch away and back; it still connects. A second archive on another server isn't affected.
    - Refusals: a CA-issued server certificate, a key file, a two-certificate file and an expired file are each refused with their message.
    - A short-lived self-signed certificate shows the warning.
    - Replace and remove under Archives › ⋮ › Certificate. Remove makes the private-CA server fail again.
    - A wrong-hostname server is refused even with the CA trusted.
    - Cancel the picker and back out of step 2.
    - Change the setup destination or server type while import is pending: its result cannot trust or connect to the changed destination. Lock the app while the picker reads: no confirmation or save starts under the lock.
    - Let a synthetic imported certificate expire between choosing and confirming, and while an API/attachment request is active. Confirmation refuses it; active requests stop and the pooled connection cannot send another request. Check suspension/resume and device-time changes too.
    - A CA file with a critical name constraint, policy constraint or extended key usage is refused with "This certificate has a rule MailBurrow can't check".
    - On Android and iOS check local and cloud document providers: cancellation, short reads, an over-64-KiB file, a stalled provider, and repeated picks while reading. On iOS also compile the native picker before testing Files providers.
11. Before public binaries also verify signed update, OS restart, missing viewer/deleted copy, low storage, real transport cancellation/timeouts, startup/memory and exact artifact metadata/notices. Host mocks do not establish these results.
