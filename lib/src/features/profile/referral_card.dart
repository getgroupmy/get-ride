import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/referral.dart';
import '../../widgets/image_share.dart';

const _brandBlue = Color(0xFF2DABE2);
const _brandBlueDark = Color(0xFF1B6E92);
const _bonusGold = Color(0xFFEAB308);

/// The shareable invite poster (Expo `ReferralPoster`): brand, who is
/// inviting, each side's bonus, the code and a QR of the invite link. It is
/// a picture to be sent, so its colours are its own in both themes.
class ReferralPosterCard extends StatelessWidget {
  const ReferralPosterCard({
    super.key,
    required this.code,
    required this.link,
    this.inviterName,
    this.referredBonus,
    this.referrerBonus,
  });

  final String code;
  final String link;
  final String? inviterName;

  /// Formatted bonus for the friend who joins, and for the inviter; null
  /// when that side earns nothing.
  final String? referredBonus, referrerBonus;

  @override
  Widget build(BuildContext context) {
    final name = (inviterName ?? '').trim();
    Widget chip(String amount, String label) => Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            const Icon(Icons.card_giftcard, color: _bonusGold, size: 18),
            const SizedBox(height: 6),
            Text(
              amount,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900),
            ),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );

    return MediaQuery.withNoTextScaling(
      child: Container(
        key: const ValueKey('referral-poster'),
        width: 320,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const LinearGradient(
            colors: [_brandBlue, _brandBlueDark],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome, color: Colors.white, size: 20),
                SizedBox(width: 7),
                Text(
                  'GET.ride',
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              referralCardHeadline(name),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 24, height: 1.2, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            Text(
              'Sign up with this code and we both earn bonus GET.coin to spend on rides.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13, height: 1.45),
            ),
            if (referredBonus != null || referrerBonus != null) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  if (referredBonus != null) chip(referredBonus!, 'for you'),
                  if (referredBonus != null && referrerBonus != null) const SizedBox(width: 10),
                  if (referrerBonus != null) chip(referrerBonus!, 'for ${name.isEmpty ? 'your friend' : name}'),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
              child: Column(
                children: [
                  const Text(
                    'YOUR REFERRAL CODE',
                    style: TextStyle(
                      color: Color(0xFF6B7280),
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      code,
                      key: const ValueKey('referral-poster-code'),
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontSize: 30,
                        letterSpacing: 3,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: QrImageView(
                      key: const ValueKey('referral-poster-qr'),
                      data: link,
                      size: 150,
                      padding: EdgeInsets.zero,
                      backgroundColor: Colors.white,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                      eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: _brandBlueDark),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: _brandBlueDark,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Scan to download GET.ride & join',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF6B7280), fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The invite card on the referral screen, with Share card and Save card:
/// the poster is captured as it is drawn, at three times its size.
class ReferralCardSection extends ConsumerStatefulWidget {
  const ReferralCardSection({
    super.key,
    required this.code,
    required this.link,
    this.inviterName,
    this.referredBonus,
    this.referrerBonus,
  });

  final String code;
  final String link;
  final String? inviterName;
  final String? referredBonus, referrerBonus;

  @override
  ConsumerState<ReferralCardSection> createState() => _ReferralCardSectionState();
}

class _ReferralCardSectionState extends ConsumerState<ReferralCardSection> {
  final _poster = GlobalKey();

  Future<ShareableImage?> _image(Rect? origin) async {
    final png = await ref.read(boundaryPngProvider)(_poster, pixelRatio: 3);
    if (png == null) return null;
    return ShareableImage(
      png: png,
      fileName: referralCardFileName(widget.code),
      text: referralMessage(widget.code, widget.link),
      subject: 'Join me on GET.ride',
      origin: origin,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your invite card', style: t.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Share it on WhatsApp or Instagram. Friends scan the QR to get the app with your code.',
          style: t.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: RepaintBoundary(
              key: _poster,
              child: ReferralPosterCard(
                code: widget.code,
                link: widget.link,
                inviterName: widget.inviterName,
                referredBonus: widget.referredBonus,
                referrerBonus: widget.referrerBonus,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        ShareSaveImageButtons(
          keyPrefix: 'referral-card',
          shareLabel: 'Share card',
          saveLabel: 'Save card',
          image: _image,
        ),
      ],
    );
  }
}
