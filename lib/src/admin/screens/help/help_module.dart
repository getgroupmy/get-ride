// Operations: the help assistant's articles and the questions it could not answer.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../admin_registry.dart';
import 'help_articles_screen.dart';

final helpRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/help-articles', builder: (_, _) => const AdminHelpArticlesScreen()),
];

const helpEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Operations',
    title: 'Help articles',
    subtitle: "The help assistant's answers, and the questions it could not answer",
    path: '/admin/m/help-articles',
    pages: [helpArticlesPage],
    icon: Icons.live_help_outlined,
  ),
];
