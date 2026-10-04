// Payments & commerce: payment types/gateways, GET.coin, EV catalogue and orders.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'commerce_logic.dart';
import '../../admin_registry.dart';
import 'ev_catalog_screens.dart';
import 'ev_orders_screen.dart';
import 'get_coin_screen.dart';
import 'payment_screens.dart';

final commerceRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/payment-type', builder: (_, _) => const PaymentTypeScreen()),
  GoRoute(path: '/admin/m/payment-gateway', builder: (_, _) => const PaymentGatewayScreen()),
  GoRoute(path: '/admin/m/get-coin', builder: (_, _) => const GetCoinScreen()),
  GoRoute(path: '/admin/m/ev-order-fee', builder: (_, _) => const EvOrderFeeScreen()),
  GoRoute(path: '/admin/m/ev-finance-options', builder: (_, _) => const EvFinanceOptionsScreen()),
  GoRoute(path: '/admin/m/ev-vehicle-details', builder: (_, _) => const EvVehicleDetailsScreen()),
  GoRoute(path: '/admin/m/ev-vehicle-inventory', builder: (_, _) => const EvVehicleInventoryScreen()),
  GoRoute(path: '/admin/m/ev-orders', builder: (_, _) => const EvOrdersScreen()),
];

const _s = 'Payments & commerce';

const commerceEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: _s,
    title: 'Payment Type',
    subtitle: 'Available payment methods',
    path: '/admin/m/payment-type',
    pages: ['admin-settings-payment-type'],
    icon: Icons.credit_card,
  ),
  AdminScreenEntry(
    section: _s,
    title: 'Payment Gateways',
    subtitle: 'Provider accounts (public configuration)',
    path: '/admin/m/payment-gateway',
    pages: ['admin-settings-payment-gateway'],
    icon: Icons.account_balance_outlined,
  ),
  AdminScreenEntry(
    section: _s,
    title: 'Get Coin',
    subtitle: 'GET.coin exchange rate, rewards and market',
    path: '/admin/m/get-coin',
    pages: ['admin-settings-get-coin'],
    icon: Icons.toll_outlined,
  ),
  AdminScreenEntry(
    section: _s,
    title: 'TEKSI EV Orders',
    subtitle: 'Review orders, assign DAs, handover checklist',
    path: '/admin/m/ev-orders',
    pages: ['admin-orders'],
    icon: Icons.inventory_2_outlined,
  ),
  AdminScreenEntry(
    section: _s,
    title: 'EV Order Fee',
    subtitle: 'Non-refundable order fee per country',
    path: '/admin/m/ev-order-fee',
    pages: ['admin-settings-ev-order-fee'],
    icon: Icons.payments_outlined,
  ),
  AdminScreenEntry(
    section: _s,
    title: 'EV Finance Options',
    subtitle: 'Cash, Leasing, Hire Purchase & Rental',
    path: '/admin/m/ev-finance-options',
    pages: ['admin-settings-ev-finance-options'],
    icon: Icons.account_balance_wallet_outlined,
  ),
  AdminScreenEntry(
    section: _s,
    title: 'EV Vehicle Details',
    subtitle: 'Models, colours, pricing & accessories',
    path: '/admin/m/ev-vehicle-details',
    pages: ['admin-settings-ev-vehicle-details'],
    icon: Icons.electric_car_outlined,
  ),
  AdminScreenEntry(
    section: _s,
    title: 'EV Vehicle Inventory',
    subtitle: 'Available units ready for fast delivery',
    path: '/admin/m/ev-vehicle-inventory',
    pages: ['admin-settings-ev-vehicle-inventory'],
    icon: Icons.warehouse_outlined,
  ),
];

/// `settings_entries` categories edited by the screens above (hidden from
/// the generic "advanced" raw-JSON list).
const commerceOwnedCategories = <String>{paymentTypeCategory, paymentGatewayCategory};
