// A number plate as the car shows it: in the country's colours for the
// vehicle (a taxi, an EV...), else white capitals on a black plate,
// kept whole (never broken after a "·" in a line of text).
import 'package:flutter/material.dart';

import '../core/permits.dart' show PlateColours;
export '../core/permits.dart' show PlateColours;

class PlateChip extends StatelessWidget {
  const PlateChip({super.key, required this.plate, this.fontSize = 18, this.colours});

  final String plate;
  final double fontSize;

  /// The country's plate colours for this vehicle (core/permits.dart); null
  /// keeps white on black.
  final PlateColours? colours;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Number plate $plate',
    excludeSemantics: true,
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: fontSize * 0.66, vertical: fontSize / 3),
      decoration: BoxDecoration(
        color: colours?.bg ?? Colors.black,
        borderRadius: BorderRadius.circular(6),
        // A thin edge, so a white plate stands out on a white card.
        border: Border.all(color: colours == null ? Theme.of(context).colorScheme.outline : const Color(0xFF888888)),
      ),
      child: Text(
        plate.toUpperCase(),
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          color: colours?.fg ?? Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
        ),
      ),
    ),
  );
}

/// A driver's rating as both ride screens show it: the star icon, then the
/// number.
class RatingStars extends StatelessWidget {
  const RatingStars({super.key, required this.rating});

  final double rating;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Rated ${rating.toStringAsFixed(1)} stars',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star, size: 18, color: Colors.amber),
        Text(rating.toStringAsFixed(1)),
      ],
    ),
  );
}

/// Whether [model] ("White Perodua Bezza") already says [colour] ("white").
bool modelStatesColour(String model, String colour) =>
    colour.trim().isNotEmpty && model.trim().toLowerCase().startsWith(colour.trim().toLowerCase());
