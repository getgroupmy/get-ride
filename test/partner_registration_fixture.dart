// Example Partner Service type settings for the partner registration tests
// (0288). Made up: no real permit, company or person.
import 'package:get_ride/src/admin/screens/people/people_logic.dart' show ServiceArea;

const regSelangor = ServiceArea(
  countries: ['Malaysia'],
  states: ['Malaysia|Selangor'],
  cities: ['Malaysia|Selangor|Ampang'],
);

/// eHailing: a vehicle service, citizens-only in Malaysia, 15 years, a
/// vehicle permit (EVP) also for a taxi. Teksi: citizens-only, a registered
/// business and the Kad Pemandu in Malaysia, 20 years, covering eHailing.
/// Delivery: no vehicle, open to everyone.
final regEntries = <Map<String, dynamic>>[
  {
    'name': 'eHailing',
    'vehicleRequired': true,
    'rules': {
      'vehicleAge': {
        'required': true,
        'rules': [
          {'country': 'Malaysia', 'maxYears': 15},
        ],
      },
    },
    'citizensOnly': {
      'required': true,
      'all': false,
      'regions': [
        {'country': 'Malaysia'},
      ],
    },
    'vehiclePermit': {
      'required': true,
      'rules': [
        {'country': 'Malaysia', 'name': 'EVP', 'issuer': 'APAD', 'permitType': 'evp'},
      ],
    },
    'vehiclePermitAlsoFor': ['Teksi'],
  },
  {
    'name': 'Teksi',
    'vehicleRequired': true,
    'rules': {
      'vehicleAge': {
        'required': true,
        'rules': [
          {'country': 'Malaysia', 'maxYears': 20},
        ],
      },
    },
    'citizensOnly': {
      'required': true,
      'all': false,
      'regions': [
        {'country': 'Malaysia'},
      ],
    },
    'businessRegistration': {
      'required': true,
      'all': false,
      'regions': [
        {'country': 'Malaysia'},
      ],
    },
    'driverPermit': {
      'required': true,
      'rules': [
        {'country': 'Malaysia', 'name': 'Kad Pemandu', 'issuer': 'APAD', 'permitType': 'kad-pemandu'},
      ],
    },
    'ageLimitCovers': [
      {
        'country': 'Malaysia',
        'types': ['eHailing'],
      },
    ],
  },
  {'name': 'Delivery', 'vehicleRequired': false},
];
