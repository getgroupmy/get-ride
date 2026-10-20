// Admin > Telematics (migration 0255): every driver, vehicle and driver in
// a vehicle — kilometres online, to pickups and with passengers (estimated
// against actual), trips by type, the period's list and its CSV. Read on
// the Telematics page (admin-telematics) or a full admin.
import 'package:flutter/material.dart';

import '../../data/telematics_repository.dart';
import '../../features/telematics/telematics_scope_view.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

/// The page's grant (`admin_access.page`).
const telematicsAdminPage = 'admin-telematics';

class AdminTelematicsScreen extends StatelessWidget {
  const AdminTelematicsScreen({super.key});

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Telematics',
    module: 'telematics',
    body: ListView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 32),
      children: const [
        ResponsiveCenter(maxWidth: 1100, child: TelematicsScopeView(scope: TelematicsScope.admin)),
      ],
    ),
  );
}
