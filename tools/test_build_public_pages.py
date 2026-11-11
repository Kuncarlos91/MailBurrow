import unittest
import re
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote
from build_public_pages import ROOT, render, public_files, validate_public_content

class PublicPagesTests(unittest.TestCase):
    def setUp(self):
        self.contact = (ROOT / "docs/security/public-contacts.md").read_text(encoding="utf-8")

    def test_templates_resolve_for_publication_without_remote_assets(self):
        for path in (ROOT / "site/templates").glob("*.html"):
            result = render(path.read_text(encoding="utf-8"), self.contact)
            self.assertNotIn("{{", result)
            self.assertIn("Carlos Diaz", result)
            self.assertNotRegex(result, r"(?i)review draft|not published|planned pages|when this notice is finalized")
            self.assertRegex(result, r"Updated November \d{1,2}, 2026")
            if path.name == "privacy.html":
                self.assertIn("Effective November 5, 2026", result)
            self.assertNotRegex(result, r"(?i)<(?:script|iframe|form|img)\b")
            self.assertNotRegex(result, r"(?i)(?:src|href)=[\"']https?://[^\"']+\.(?:css|js)")
            self.assertIn('href="styles.css"', result)

    def test_missing_identity_fails(self):
        with self.assertRaises(ValueError):
            render("test", "")

    def test_unapproved_identity_fails(self):
        with self.assertRaises(ValueError):
            render("test", self.contact.replace("Carlos Diaz", "Another Provider"))

    def test_unknown_marker_fails(self):
        with self.assertRaises(ValueError):
            render("{{UNKNOWN}}", self.contact)


class PublicPackageTests(unittest.TestCase):
    def setUp(self):
        self.contact = (ROOT / "docs/security/public-contacts.md").read_text(encoding="utf-8")
        self.files = public_files(self.contact)

    def test_only_reviewed_static_files_are_packaged(self):
        self.assertEqual(set(self.files), {"index.html", "setup.html", "privacy.html", "styles.css", "_headers"})
        for value in self.files.values():
            validate_public_content(value)

    def test_all_local_links_and_fragment_targets_exist(self):
        class Links(HTMLParser):
            def __init__(self):
                super().__init__()
                self.links, self.ids = [], set()
            def handle_starttag(self, tag, attrs):
                attrs = dict(attrs)
                if "id" in attrs:
                    self.ids.add(attrs["id"])
                for key in ("href", "src"):
                    if key in attrs:
                        self.links.append(attrs[key])
        parsed = {}
        for name in ("index.html", "setup.html", "privacy.html"):
            page = Links()
            page.feed(self.files[name])
            parsed[name] = page
            self.assertIn("main", page.ids)
        for name, page in parsed.items():
            for link in page.links:
                target = urlsplit(link)
                if target.scheme or target.netloc:
                    continue
                path = unquote(target.path) or name
                self.assertIn(path, self.files)
                if target.fragment:
                    self.assertIn(unquote(target.fragment), parsed[path].ids)

    def test_host_policy_blocks_scripts_and_referrer_disclosure(self):
        headers = self.files["_headers"]
        self.assertIn("default-src 'none'", headers)
        self.assertIn("form-action 'none'", headers)
        self.assertIn("frame-ancestors 'none'", headers)
        self.assertIn("Referrer-Policy: no-referrer", headers)
        self.assertIn("X-Content-Type-Options: nosniff", headers)

    def test_approved_contact_does_not_clear_adjacent_secrets(self):
        approved = render("{{PUBLIC_CONTACT_EMAIL}}", self.contact)
        credential = "api" + "_key = '" + "q" * 32 + "'"
        with self.assertRaises(ValueError):
            validate_public_content(approved + " " + credential)

    def test_unknown_contact_and_private_host_fail_closed(self):
        with self.assertRaises(ValueError):
            validate_public_content("unexpected" + "@" + "gmail.com")
        with self.assertRaises(ValueError):
            validate_public_content("customer" + ".ts" + ".net")

    def test_current_copy_preserves_platform_and_service_boundaries(self):
        support, privacy = self.files["index.html"], self.files["privacy.html"]
        self.assertIn("early preview for Android and iOS", support)
        self.assertIn("signed Android prerelease for 64-bit ARM phones", support)
        self.assertIn("releases/tag/v0.3.0-rc.9", support)
        self.assertIn("MailBurrow limits attachment downloads", support)
        self.assertIn("This recovery action is Android-only", support)
        self.assertIn("Issues are public", support)
        self.assertIn("Report security problems privately", support)
        self.assertIn("Issues, comments and pull requests you post there are public", privacy)
        self.assertIn("no broad media-library access".lower(), privacy.lower())
        self.assertIn("Each month", privacy)
        self.assertIn("12 months or more", privacy)
        self.assertIn("leave file-operation diagnostic tracing disabled", privacy)
        self.assertIn("Try the demo", support)
        self.assertIn("connects to no server", support)
        self.assertIn("connects to no server, sends nothing over the network", privacy)
        self.assertNotIn("Final SDK", privacy)
        self.assertNotIn("Review still required before publication", privacy)
        for page in (support, privacy):
            self.assertNotIn("Local review draft", page)
            self.assertIn("MailBurrow was previously distributed as MailShelf", page)
            self.assertNotIn("PUBLIC_", page)


    def test_setup_page_keeps_the_service_boundary_and_safety_rules(self):
        setup = self.files["setup.html"]
        for phrase in ("Api__Enabled", "2607.3 or later", "inherits the permissions of the user who creates it",
                       "Self-signed certificates don't work", "No redirects.", "tailscale serve --bg 30315",
                       "Never paste it into chats", "Try the demo", "is not the official Mail-Archiver or Tailscale app"):
            self.assertIn(phrase, setup)
        for name in ("index.html", "setup.html", "privacy.html"):
            self.assertIn('href="setup.html"', self.files[name])
        self.assertNotRegex(setup, r"(?i)<(?:script|iframe|form|img)\b")

    def test_skip_target_accepts_keyboard_focus(self):
        for name in ("index.html", "setup.html", "privacy.html"):
            self.assertIn('<main id="main" tabindex="-1">', self.files[name])

    def test_body_link_and_notice_colors_have_readable_contrast(self):
        def luminance(color):
            channels = [int(color[i:i+2], 16) / 255 for i in (1, 3, 5)]
            linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
            return sum(c * weight for c, weight in zip(linear, (0.2126, 0.7152, 0.0722)))
        schemes = re.findall(r":root\{([^}]+)\}", self.files["styles.css"])
        self.assertEqual(len(schemes), 2)
        for scheme in schemes:
            colors = dict(re.findall(r"--([a-z-]+):(#(?:[a-fA-F0-9]{6}))", scheme))
            for text, background in (("fg", "bg"), ("link", "bg"), ("muted", "bg"), ("fg", "surface")):
                light, dark = sorted((luminance(colors[text]), luminance(colors[background])), reverse=True)
                self.assertGreaterEqual((light + 0.05) / (dark + 0.05), 4.5)


class PublicAccuracyTests(unittest.TestCase):
    def test_material_privacy_boundaries_are_explicit(self):
        contact = (ROOT / "docs/security/public-contacts.md").read_text(encoding="utf-8")
        files = public_files(contact)
        support, privacy = files["index.html"], files["privacy.html"]
        self.assertIn("do not cover the system save picker", support)
        self.assertNotIn("two minutes total", support)
        self.assertIn("attempts to release read grants", privacy)
        self.assertIn("Pre-existing retained permissions", privacy)
        self.assertIn("upload or synchronize the attachment", privacy)
        self.assertIn("unencrypted HTTP", privacy)
        self.assertIn("not automatically removed", privacy)
        self.assertIn("does not verify", support)
        self.assertIn("After an open failure", privacy)
