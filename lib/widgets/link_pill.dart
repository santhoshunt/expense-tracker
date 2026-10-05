import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/contrast.dart';
import 'undo_snackbar.dart';

/// The app's link: a quiet pill with the accent on its edge and arrow. An
/// in-app destination ends in an arrow; a web page ([external]) ends in the
/// open-in-new mark, and a long press shows [fullUrl] when the label is a
/// shortened address.
class LinkPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool external;
  final String? fullUrl;

  const LinkPill({
    super.key,
    required this.label,
    required this.onTap,
    this.external = false,
    this.fullUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = accentTextColor(context);
    // excludeSemantics drops the InkWell's own tap action, so the tap is
    // exposed here for TalkBack.
    final pill = Semantics(
      link: true,
      label: fullUrl ?? label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: StadiumBorder(
          side: BorderSide(color: accent.withValues(alpha: 0.55)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            // 40dp keeps the pill a comfortable target inside running text.
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    external ? Icons.open_in_new : Icons.arrow_forward,
                    size: 16,
                    color: accent,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (fullUrl == null) return pill;
    return Tooltip(
      message: fullUrl,
      triggerMode: TooltipTriggerMode.longPress,
      child: pill,
    );
  }
}

/// A web address as a short pill label: the host, plus the last path
/// segment when there is a path ("github.com/…/v1.33.1").
String linkPillLabel(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  final host = uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return host;
  if (segments.length == 1) return '$host/${segments.single}';
  return '$host/…/${segments.last}';
}

final _urlPattern = RegExp(r'https?://[^\s<>"]+');

/// [raw] without the punctuation that ends its sentence ("see
/// https://x.y/z."). A closing parenthesis stays when the address opened
/// one ("…/wiki/Foo_(bar)").
String _trimUrl(String raw) {
  var url = raw;
  while (url.isNotEmpty) {
    final last = url[url.length - 1];
    final unbalanced =
        last == ')' && ')'.allMatches(url).length > '('.allMatches(url).length;
    if (!".,;:!?'*]".contains(last) && !unbalanced) break;
    url = url.substring(0, url.length - 1);
  }
  return url;
}

/// Opens [url] in the browser, or says so when it can't.
Future<void> openWebLink(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final uri = Uri.tryParse(url);
  final opened =
      uri != null &&
      await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      ).catchError((_) => false);
  if (!opened && messenger != null) {
    showAppToastOn(
      messenger,
      "Couldn't open the link.",
      tone: AppToastTone.error,
    );
  }
}

/// [text] with each web address drawn as a [LinkPill] that opens it in the
/// browser. Punctuation that ends a sentence stays out of the address.
class LinkifiedText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const LinkifiedText(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _urlPattern.allMatches(text)) {
      final url = _trimUrl(m.group(0)!);
      if (url.isEmpty) continue;
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          // A WidgetSpan already scales its child by the font size; without
          // this the pill's own Text scaled a second time.
          child: MediaQuery.withNoTextScaling(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: LinkPill(
                label: linkPillLabel(url),
                external: true,
                fullUrl: url,
                onTap: () => openWebLink(context, url),
              ),
            ),
          ),
        ),
      );
      at = m.start + url.length;
    }
    if (spans.isEmpty) return Text(text, style: style);
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(children: spans), style: style);
  }
}
