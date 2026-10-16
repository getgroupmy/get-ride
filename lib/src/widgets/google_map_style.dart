// Google's dark style for the roadmap, shared by its JavaScript map (the
// `styles` option, on the web and in the desktop web view) and its own map
// in the phone app (as JSON).
import 'dart:convert';

const googleNightStyle = [
  {
    'elementType': 'geometry',
    'stylers': [
      {'color': '#242f3e'},
    ],
  },
  {
    'elementType': 'labels.text.stroke',
    'stylers': [
      {'color': '#242f3e'},
    ],
  },
  {
    'elementType': 'labels.text.fill',
    'stylers': [
      {'color': '#746855'},
    ],
  },
  {
    'featureType': 'road',
    'elementType': 'geometry',
    'stylers': [
      {'color': '#38414e'},
    ],
  },
  {
    'featureType': 'road',
    'elementType': 'geometry.stroke',
    'stylers': [
      {'color': '#212a37'},
    ],
  },
  {
    'featureType': 'road',
    'elementType': 'labels.text.fill',
    'stylers': [
      {'color': '#9ca5b3'},
    ],
  },
  {
    'featureType': 'road.highway',
    'elementType': 'geometry',
    'stylers': [
      {'color': '#746855'},
    ],
  },
  {
    'featureType': 'water',
    'elementType': 'geometry',
    'stylers': [
      {'color': '#17263c'},
    ],
  },
  {
    'featureType': 'water',
    'elementType': 'labels.text.fill',
    'stylers': [
      {'color': '#515c6d'},
    ],
  },
  {
    'featureType': 'poi',
    'elementType': 'labels.text.fill',
    'stylers': [
      {'color': '#d59563'},
    ],
  },
  {
    'featureType': 'poi.park',
    'elementType': 'geometry',
    'stylers': [
      {'color': '#263c3f'},
    ],
  },
  {
    'featureType': 'transit',
    'elementType': 'geometry',
    'stylers': [
      {'color': '#2f3948'},
    ],
  },
];

/// [googleNightStyle] as the JSON Google's phone map takes.
final googleNightStyleJson = jsonEncode(googleNightStyle);
