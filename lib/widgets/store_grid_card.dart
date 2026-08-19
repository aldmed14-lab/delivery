import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// Shared 2-per-row store card: image-top, open/closed badge overlaid on
/// the image, name, then rating + delivery time on one row. Used by both
/// the home page's store grid and the search page's results grid so the
/// two stay visually identical.
class StoreGridCard extends StatelessWidget {
  final String name;
  final String isOpen;
  final String imageUrl;
  final int rateNumbers;
  final double rating;
  final int? deliveryMinutes;
  final VoidCallback onTap;

  const StoreGridCard({
    required this.name,
    required this.isOpen,
    required this.imageUrl,
    required this.rateNumbers,
    required this.rating,
    required this.deliveryMinutes,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final openText = TranslationHelper.get('store_open');
    final closedText = TranslationHelper.get('store_closed');
    final trafic = TranslationHelper.get('store_busy');
    final noRatingsText = TranslationHelper.get('no_ratings_yet');

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(16)),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        color: Colors.grey[300],
                        child: const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFFFF9800),
                            ),
                          ),
                        ),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.restaurant, color: Colors.grey),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isOpen == "open"
                          ? Colors.green[100]
                          : Colors.red[100],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      isOpen == "open"
                          ? openText
                          : isOpen == "close"
                              ? closedText
                              : trafic,
                      style: TextStyle(
                        color: isOpen == "open"
                            ? Colors.green[800]
                            : Colors.red[800],
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  if (rateNumbers <= 100)
                    Text(
                      noRatingsText,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    Row(
                      children: [
                        const Icon(Icons.star, color: Colors.amber, size: 12),
                        const SizedBox(width: 3),
                        Text(
                          (rating / rateNumbers).toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (deliveryMinutes != null) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.access_time,
                              size: 11, color: Colors.grey[500]),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              '$deliveryMinutes ${TranslationHelper.get('min')}',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey[600],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
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

/// Matching skeleton placeholder for a [StoreGridCard], for loading states.
class StoreGridCardSkeleton extends StatelessWidget {
  const StoreGridCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withValues(alpha: 0.1),
            spreadRadius: 1,
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(color: Colors.grey[300]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 14,
                  width: 90,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 12,
                  width: 50,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The standard store grid delegate every store grid in the app uses -
/// keeps the home page and search results visually identical.
///
/// Uses [SliverGridDelegateWithMaxCrossAxisExtent] instead of a fixed
/// column count so each card's width is capped (~190) rather than
/// stretching to fill half the viewport. A card's actual content (a
/// 16:9 image plus one short text block) is much shorter than it is
/// wide, so letting cards grow wide on tablets/large phones - as a fixed
/// 2-column, 1:1-aspect grid does - left a large empty gap under the
/// text on every card. Capping the width keeps the aspect ratio close
/// to the content's real proportions on every screen size instead.
const storeGridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 190,
  mainAxisSpacing: 12,
  crossAxisSpacing: 12,
  childAspectRatio: 1.15,
);
