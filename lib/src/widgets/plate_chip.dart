// A number plate as the car shows it: white capitals on a black plate,
// kept whole (never broken after a "·" in a line of text).
import 'package:flutter/material.dart';

class PlateChip extends StatelessWidget {
  const PlateChip({super.key, required this.plate, this.fontSize = 18});

  final String plate;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: fontSize * 0.66, vertical: fontSize / 3),
    decoration: BoxDecoration(
      color: Colors.black,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Theme.of(context).colorScheme.outline),
    ),
    child: Text(
      plate.toUpperCase(),
      maxLines: 1,
      softWrap: false,
      style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w800, letterSpacing: 1.5),
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
