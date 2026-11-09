import 'dart:convert';
import 'dart:async';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'package:url_launcher/url_launcher.dart';

Uri? webLink(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

String safeEmailHtml(String html) {
  final document = parser.parse(html);
  if (complexEmailDocument(document)) {
    throw const FormatException('Message requires simple text view');
  }
  const allowed = {
    'p',
    'div',
    'span',
    'br',
    'hr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'strong',
    'b',
    'em',
    'i',
    'u',
    's',
    'blockquote',
    'pre',
    'code',
    'ul',
    'ol',
    'li',
    'a',
    'table',
    'thead',
    'tbody',
    'tfoot',
    'tr',
    'td',
    'th',
  };
  const discard = {
    'head',
    'style',
    'script',
    'noscript',
    'template',
    'img',
    'picture',
    'svg',
    'iframe',
    'object',
    'embed',
    'video',
    'audio',
    'source',
    'link',
    'meta',
    'input',
    'button',
    'select',
    'textarea',
  };
  String render(dom.Node node) {
    if (node is dom.Text) {
      return const HtmlEscape(HtmlEscapeMode.element).convert(node.data);
    }
    if (node is! dom.Element || discard.contains(node.localName)) return '';
    final content = node.nodes.map(render).join();
    final tag = node.localName;
    if (!allowed.contains(tag)) return content;
    if (tag == 'a') {
      final uri = webLink(node.attributes['href'] ?? '');
      return uri == null
          ? content
          : '<a href="${const HtmlEscape(HtmlEscapeMode.attribute).convert(uri.toString())}">$content</a>';
    }
    if (tag == 'br' || tag == 'hr') return '<$tag>';
    return '<$tag>$content</$tag>';
  }

  return document.body?.nodes.map(render).join() ?? '';
}

String plainEmailHtml(String text) {
  final escaped = const HtmlEscape(HtmlEscapeMode.attribute).convert(text);
  return escaped
      .replaceAllMapped(RegExp(r'https?://[^\s<>]+'), (match) {
        final value = match.group(0)!;
        final decoded = parser.parseFragment(value).text ?? value;
        return webLink(decoded) == null ? value : '<a href="$value">$value</a>';
      })
      .replaceAll('\n', '<br>');
}

const maxEmailHtmlLength = 256000;
const maxEmailTextLength = 100000;
const emailTextPageLength = 4000;

class PreparedEmailBody {
  const PreparedEmailBody(
    this.html,
    this.text, {
    this.notice,
    this.displayDetails = '',
    this.textLimited = false,
  });
  final String html, text;
  final String? notice;
  final String displayDetails;
  final bool textLimited;
}

bool complexEmailDocument(dom.Document document) {
  final stack = <(dom.Node, int, int)>[(document, 0, 0)];
  var nodes = 0, cells = 0;
  while (stack.isNotEmpty) {
    final (node, depth, tables) = stack.removeLast();
    if (++nodes > 1200 || depth > 24) return true;
    final tag = node is dom.Element ? node.localName : '';
    final nestedTables = tables + (tag == 'table' ? 1 : 0);
    if (nestedTables > 1) return true;
    if ((tag == 'td' || tag == 'th') && ++cells > 160) return true;
    for (final child in node.nodes) {
      stack.add((child, depth + 1, nestedTables));
    }
  }
  return false;
}

String emailDocumentText(dom.Document document) {
  final out = StringBuffer();
  final stack = <dom.Node>[...?document.body?.nodes.reversed];
  while (stack.isNotEmpty && out.length < maxEmailTextLength + 1) {
    final node = stack.removeLast();
    if (node is dom.Text) {
      out.write(node.data);
    } else if (node is dom.Element) {
      if ({
        'style',
        'script',
        'template',
        'head',
        'noscript',
        'svg',
        'iframe',
        'object',
      }.contains(node.localName)) {
        continue;
      }
      if ({
        'p',
        'div',
        'br',
        'tr',
        'td',
        'li',
        'blockquote',
        'h1',
        'h2',
        'h3',
      }.contains(node.localName)) {
        out.write('\n');
      }
      stack.addAll(node.nodes.reversed);
    }
  }
  return out.toString().trim();
}

// Flatten email layout tables before handing markup to Flutter's renderer.
// This traversal is iterative and bounded; no original CSS/resources survive.
String? linearEmailHtml(
  dom.Document document, {
  void Function(String)? onRejected,
}) {
  String? reject(String reason) {
    onRejected?.call(reason);
    return null;
  }

  final out = StringBuffer();
  final stack = <(dom.Node, int, bool)>[
    for (final node in document.body?.nodes.reversed ?? <dom.Node>[])
      (node, 0, false),
  ];
  const discard = {
    'head',
    'style',
    'script',
    'noscript',
    'template',
    'img',
    'picture',
    'svg',
    'iframe',
    'object',
    'embed',
    'video',
    'audio',
    'source',
    'link',
    'meta',
    'input',
    'button',
    'select',
    'textarea',
  };
  const semantic = {
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'strong',
    'b',
    'em',
    'i',
    'u',
    's',
    'ul',
    'ol',
    'li',
    'blockquote',
    'pre',
    'code',
    'a',
  };
  const layout = {
    'table',
    'thead',
    'tbody',
    'tfoot',
    'tr',
    'td',
    'th',
    'div',
    'center',
  };
  var visited = 0;
  while (stack.isNotEmpty) {
    final (node, depth, closing) = stack.removeLast();
    if (node is dom.Text) {
      out.write(const HtmlEscape(HtmlEscapeMode.element).convert(node.data));
    } else if (node is dom.Element) {
      final tag = node.localName;
      if (discard.contains(tag)) continue;
      if (closing) {
        if (semantic.contains(tag)) out.write('</$tag>');
        if (layout.contains(tag)) out.write('<br>');
      } else {
        if (++visited > 1600) return reject('layout-node-limit');
        if (depth > 64) return reject('layout-depth-limit');
        if (tag == 'a') {
          final uri = webLink(node.attributes['href'] ?? '');
          if (uri != null) {
            out.write(
              '<a href="${const HtmlEscape(HtmlEscapeMode.attribute).convert(uri.toString())}">',
            );
            stack.add((node, depth, true));
          }
        } else if (semantic.contains(tag)) {
          out.write('<$tag>');
          stack.add((node, depth, true));
        } else if (layout.contains(tag)) {
          out.write('<br>');
          stack.add((node, depth, true));
        } else if (tag == 'br' || tag == 'hr') {
          out.write('<$tag>');
        }
        for (final child in node.nodes.reversed) {
          stack.add((child, depth + 1, false));
        }
      }
    }
    if (out.length > 48000) return reject('intermediate-markup-limit');
  }
  final html = out.toString().replaceAll(
    RegExp(r'(?:\s*<br>\s*){3,}'),
    '<br><br>',
  );
  if (html.length > 32000) return reject('rendered-markup-limit');
  // Reapply the renderer budget to the flattened result, including text nodes.
  if (complexEmailDocument(parser.parse(html))) {
    return reject('flattened-layout-budget');
  }
  if (RegExp(r'https?://').allMatches(html).length > 100) {
    return reject('link-count-limit');
  }
  return html;
}

PreparedEmailBody prepareEmailBody(String html, String text) {
  final htmlLimited = html.length > maxEmailHtmlLength;
  final source = html.length > maxEmailHtmlLength
      ? html.substring(0, maxEmailHtmlLength)
      : html;
  final document = parser.parse(source);
  final extracted = emailDocumentText(document);
  var plain = text.trim().isNotEmpty ? text : extracted;
  final textLimited = plain.length > maxEmailTextLength;
  if (plain.length > maxEmailTextLength) {
    plain = plain.substring(0, maxEmailTextLength);
  }
  if (plain.trim().isEmpty) plain = 'This message has no readable body.';
  PreparedEmailBody finish(
    String markup,
    String reason, {
    String? notice,
  }) => PreparedEmailBody(
    markup,
    plain,
    notice: notice,
    textLimited: textLimited,
    displayDetails:
        'Reason: $reason\nHTML characters: ${html.length}\nAPI text characters: ${text.length}\nHTML visible-text characters: ${extracted.length}\nRendered markup characters: ${markup.length}\nText preview limited: $textLimited',
  );
  final complex =
      htmlLimited || complexEmailDocument(document) || source.length > 32000;
  if (complex) {
    var reason = htmlLimited
        ? 'html-input-limit'
        : extracted.length > 16000
        ? 'html-visible-text-limit'
        : 'no-readable-html';
    if (!htmlLimited && extracted.isNotEmpty && extracted.length <= 16000) {
      final linear = linearEmailHtml(
        document,
        onRejected: (value) => reason = value,
      );
      if (linear != null) {
        return finish(
          linear,
          'linear-layout',
          notice: 'Simplified layout: complex tables are shown as text blocks.',
        );
      }
    }
    return finish(
      '',
      reason,
      notice: htmlLimited || textLimited
          ? 'Large message: showing a limited text preview. The full message remains on your archive server.'
          : 'Simplified text view: this message has complex formatting.',
    );
  }
  final visibleLength = extracted.isEmpty ? plain.length : extracted.length;
  if (visibleLength > 16000) {
    return finish(
      '',
      extracted.isEmpty ? 'text-body-limit' : 'html-visible-text-limit',
      notice: textLimited
          ? 'Large message: showing a limited text preview. The full message remains on your archive server.'
          : 'Simplified text view for a long message.',
    );
  }
  final cleaned = extracted.isEmpty
      ? plainEmailHtml(plain)
      : safeEmailHtml(source);
  // Avoid sending very long text or hundreds of auto-linked URLs to HTML layout.
  if (RegExp(r'https?://').allMatches(cleaned).length > 100) {
    return finish(
      '',
      'link-count-limit',
      notice: 'Simplified text view for a long message.',
    );
  }
  return finish(
    cleaned,
    extracted.isEmpty ? 'formatted-text' : 'formatted-html',
  );
}

void _prepareEmailWorker(List<Object> input) {
  final port = input[0] as SendPort;
  try {
    port.send(prepareEmailBody(input[1] as String, input[2] as String));
  } catch (_) {
    port.send(null);
  }
}

Future<PreparedEmailBody> prepareEmailBodyAsync(
  String html,
  String text,
) async {
  final port = ReceivePort();
  Isolate? worker;
  try {
    worker = await Isolate.spawn(_prepareEmailWorker, <Object>[
      port.sendPort,
      html,
      text,
    ]);
    final prepared = await port.first.timeout(const Duration(seconds: 5));
    if (prepared is PreparedEmailBody) return prepared;
  } catch (_) {
    // Never log message contents or parsing exceptions containing private data.
  } finally {
    worker?.kill(priority: Isolate.immediate);
    port.close();
  }
  final fallback = text.length > maxEmailTextLength
      ? text.substring(0, maxEmailTextLength)
      : text;
  return PreparedEmailBody(
    '',
    fallback.trim().isEmpty
        ? 'This message could not be displayed. Open it in your archive website.'
        : fallback,
    notice:
        'Formatted view unavailable. Showing a limited text preview when available.',
    textLimited: text.length > maxEmailTextLength,
    displayDetails:
        'Reason: preparation-unavailable-or-timed-out\nHTML characters: ${html.length}\nAPI text characters: ${text.length}',
  );
}

class MessageBody extends StatefulWidget {
  const MessageBody({super.key, required this.body});
  final PreparedEmailBody body;
  @override
  State<MessageBody> createState() => _MessageBodyState();
}

class _MessageBodyState extends State<MessageBody> {
  bool simple = false;
  int page = 0;
  Widget detailsButton() => TextButton(
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Message display details'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'These details contain counts and a display reason only. No message text, addresses, links, or keys are included.',
              ),
              const SizedBox(height: 16),
              SelectableText(widget.body.displayDetails),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
    child: const Text('Message display details'),
  );
  @override
  void didUpdateWidget(covariant MessageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.body, widget.body)) {
      page = 0;
      simple = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final prepared = widget.body;
    final pages = (prepared.text.length / emailTextPageLength).ceil().clamp(
      1,
      1000,
    );
    final start = page * emailTextPageLength;
    final end = (start + emailTextPageLength).clamp(0, prepared.text.length);
    if (simple || prepared.html.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (prepared.displayDetails.isNotEmpty) detailsButton(),
          if (simple && prepared.html.isNotEmpty && prepared.textLimited)
            const Text(
              'Showing a limited text preview. The full message remains on your archive server.',
            ),
          if (prepared.notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(prepared.notice!),
            ),
          SelectionArea(
            child: Text(
              prepared.text.substring(start, end),
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(height: 1.65),
            ),
          ),
          if (pages > 1)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: page == 0 ? null : () => setState(() => page--),
                  child: const Text('Previous text section'),
                ),
                Text('Text section ${page + 1} of $pages'),
                TextButton(
                  onPressed: page + 1 >= pages
                      ? null
                      : () => setState(() => page++),
                  child: const Text('Next text section'),
                ),
              ],
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (prepared.notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(prepared.notice!),
          ),
        TextButton(
          onPressed: () => setState(() => simple = true),
          child: const Text('Use simple text view'),
        ),
        if (prepared.displayDetails.isNotEmpty) detailsButton(),
        formattedBody(context, prepared.html),
      ],
    );
  }

  Widget formattedBody(BuildContext context, String body) {
    return SelectionArea(
      child: HtmlWidget(
        body,
        textStyle: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(height: 1.65),
        onTapUrl: (value) async {
          final uri = webLink(value);
          if (uri == null) return true;
          final approved = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Open external link?'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      uri.host,
                      style: Theme.of(dialogContext).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    SelectableText(uri.toString()),
                    const SizedBox(height: 16),
                    const Text(
                      'Link labels can disguise the actual destination. This site has not been checked for phishing. Open only if you trust the destination.',
                    ),
                    if (uri.scheme == 'http')
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text('This destination uses unencrypted HTTP.'),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Open browser'),
                ),
              ],
            ),
          );
          if (approved != true || !context.mounted) return true;
          try {
            if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
              return true;
            }
          } catch (_) {}
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Could not open this link in a browser.'),
              ),
            );
          }
          return true;
        },
      ),
    );
  }
}
