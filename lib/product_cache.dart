import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_database.dart';

class ProductSearchCache {
  ProductSearchCache._();

  static final ProductSearchCache instance = ProductSearchCache._();

  Future<void>? _syncFuture;
  Object? lastSyncError;
  DateTime? lastSyncAt;

  Future<Database> get database async {
    final db = await OfflineDatabase.instance.database;
    final syncValue = Sqflite.firstIntValue(
      await db.rawQuery("select cast(value as integer) from cache_meta where key = 'last_sync_ms' limit 1"),
    );
    if (syncValue != null && lastSyncAt == null) {
      lastSyncAt = DateTime.fromMillisecondsSinceEpoch(syncValue, isUtc: true);
    }
    return db;
  }

  Future<bool> get hasData async {
    final count = await productCount;
    return count > 0;
  }

  Future<int> get productCount async {
    final db = await database;
    return Sqflite.firstIntValue(await db.rawQuery('select count(*) from products')) ?? 0;
  }

  Future<List<Map<String, dynamic>>> search(String query, {int limit = 300}) async {
    final normalized = normalizeProductSearch(query);
    if (normalized.isEmpty) return const [];
    final db = await database;
    final numericQuery = int.tryParse(normalized);
    final words = normalized.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).take(6).toList();
    final where = <String>[];
    final args = <Object?>[];

    if (numericQuery != null) {
      where.add('''
        (cast(product.mat_num as text) like ?
          or exists (
            select 1 from product_barcodes barcode
            where barcode.mat_num = product.mat_num and barcode.barcode like ?
          ))
      ''');
      args
        ..add('%$normalized%')
        ..add('%$normalized%');
    } else {
      for (final word in words) {
        where.add('product.normalized_name like ?');
        args.add('%$word%');
      }
    }

    final orderSql = numericQuery != null
        ? '''
          case
            when cast(product.mat_num as text) = ? then 0
            when exists (
              select 1 from product_barcodes exact_barcode
              where exact_barcode.mat_num = product.mat_num and exact_barcode.barcode = ?
            ) then 0
            when cast(product.mat_num as text) like ? then 1
            else 2
          end,
          product.mat_num
        '''
        : '''
          case
            when product.normalized_name = ? then 0
            when product.normalized_name like ? then 1
            else 2
          end,
          length(product.normalized_name),
          product.mat_num
        ''';
    final orderArgs = numericQuery != null
        ? <Object?>[normalized, normalized, '$normalized%']
        : <Object?>[normalized, '$normalized%'];
    final rows = await db.rawQuery(
      '''
        select product.row_json,
          (select barcode.barcode from product_barcodes barcode
           where barcode.mat_num = product.mat_num limit 1) as cached_barcode
        from products product
        where ${where.isEmpty ? '1 = 0' : where.join(' and ')}
        order by $orderSql
        limit ?
      ''',
      [...args, ...orderArgs, limit],
    );
    return rows.map(_decodeProduct).whereType<Map<String, dynamic>>().toList();
  }

  Future<List<Map<String, dynamic>>> allProducts() async {
    final db = await database;
    final rows = await db.rawQuery('''
      select product.row_json,
        (select barcode.barcode from product_barcodes barcode
         where barcode.mat_num = product.mat_num limit 1) as cached_barcode
      from products product
    ''');
    return rows.map(_decodeProduct).whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<int, String>> allBarcodes() async {
    final db = await database;
    final rows = await db.query('product_barcodes', columns: ['mat_num', 'barcode']);
    return {
      for (final row in rows)
        if (row['mat_num'] is int && row['barcode'] != null) row['mat_num'] as int: row['barcode'].toString(),
    };
  }

  Future<List<Map<String, dynamic>>> stockForMatNums(Iterable<int> matNums) async {
    final ids = matNums.toSet().toList(growable: false);
    if (ids.isEmpty) return <Map<String, dynamic>>[];
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await (await database).rawQuery(
      'select mat_num, sto_num, quantity, updated_at from product_stock where mat_num in ($placeholders)',
      ids,
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> synchronize(SupabaseClient client, {bool force = false}) {
    final running = _syncFuture;
    if (running != null) return running;
    if (!force && lastSyncAt != null && DateTime.now().toUtc().difference(lastSyncAt!) < const Duration(minutes: 15)) {
      return Future.value();
    }
    final future = _synchronize(client);
    _syncFuture = future;
    return future.whenComplete(() => _syncFuture = null);
  }

  Future<void> _synchronize(SupabaseClient client) async {
    final db = await database;
    lastSyncError = null;
    try {
      await db.delete('products_stage');
      await db.delete('product_barcodes_stage');

      var from = 0;
      const pageSize = 750;
      while (true) {
        final rows = await client
            .from('products')
            .select()
            .order('mat_num', ascending: true)
            .range(from, from + pageSize - 1);
        final page = rows.cast<Map<String, dynamic>>();
        final batch = db.batch();
        for (final product in page) {
          final matNum = _intValue(product['mat_num']);
          if (matNum == null) continue;
          batch.insert(
            'products_stage',
            {
              'mat_num': matNum,
              'normalized_name': normalizeProductSearch(product['name']?.toString() ?? ''),
              'row_json': jsonEncode(product),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
        if (page.length < pageSize) break;
        from += pageSize;
      }

      var barcodeSyncSucceeded = true;
      try {
        from = 0;
        while (true) {
          final rows = await client
              .from('product_barcodes')
              .select('mat_num, barcode')
              .order('mat_num', ascending: true)
              .order('barcode', ascending: true)
              .range(from, from + pageSize - 1);
          final page = rows.cast<Map<String, dynamic>>();
          final batch = db.batch();
          for (final row in page) {
            final matNum = _intValue(row['mat_num']);
            final barcode = row['barcode']?.toString().trim();
            if (matNum == null || barcode == null || barcode.isEmpty) continue;
            batch.insert(
              'product_barcodes_stage',
              {'mat_num': matNum, 'barcode': barcode},
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
          }
          await batch.commit(noResult: true);
          if (page.length < pageSize) break;
          from += pageSize;
        }
      } catch (_) {
        barcodeSyncSucceeded = false;
      }

      var stockSyncSucceeded = true;
      try {
        await db.delete('product_stock_stage');
        from = 0;
        while (true) {
          final rows = await client
              .from('product_stock')
              .select('mat_num, sto_num, quantity')
              .order('mat_num', ascending: true)
              .order('sto_num', ascending: true)
              .range(from, from + pageSize - 1);
          final page = rows.cast<Map<String, dynamic>>();
          final batch = db.batch();
          for (final row in page) {
            final matNum = _intValue(row['mat_num']);
            final branchNum = _intValue(row['sto_num']);
            if (matNum == null || branchNum == null) continue;
            batch.insert(
              'product_stock_stage',
              {
                'mat_num': matNum,
                'sto_num': branchNum,
                'quantity': _doubleValue(row['quantity']),
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await batch.commit(noResult: true);
          if (page.length < pageSize) break;
          from += pageSize;
        }
      } catch (_) {
        stockSyncSucceeded = false;
      }

      final stagedCount = Sqflite.firstIntValue(await db.rawQuery('select count(*) from products_stage')) ?? 0;
      if (stagedCount == 0) throw StateError('لم تُرجع قاعدة البيانات أي كتب لتحديث النسخة المحلية');

      final now = DateTime.now().toUtc();
      await db.transaction((transaction) async {
        if (!barcodeSyncSucceeded) {
          await transaction.rawInsert('insert or ignore into product_barcodes_stage select * from product_barcodes');
        }
        await transaction.delete('products');
        await transaction.rawInsert('insert into products select * from products_stage');
        await transaction.delete('product_barcodes');
        await transaction.rawInsert('insert into product_barcodes select * from product_barcodes_stage');
        if (stockSyncSucceeded) {
          await transaction.delete('product_stock');
          await transaction.rawInsert('insert into product_stock select * from product_stock_stage');
        }
        await transaction.insert(
          'cache_meta',
          {'key': 'last_sync_ms', 'value': now.millisecondsSinceEpoch.toString()},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
      lastSyncAt = now;
      OfflineDatabase.instance.notifyChanged('products');
    } catch (error) {
      lastSyncError = error;
      rethrow;
    } finally {
      await db.delete('products_stage');
      await db.delete('product_barcodes_stage');
      await db.delete('product_stock_stage');
    }
  }

  Map<String, dynamic>? _decodeProduct(Map<String, Object?> row) {
    try {
      final decoded = jsonDecode(row['row_json']?.toString() ?? '');
      if (decoded is! Map) return null;
      return {
        ...Map<String, dynamic>.from(decoded),
        if (row['cached_barcode'] != null) '_cached_barcode': row['cached_barcode'].toString(),
      };
    } catch (_) {
      return null;
    }
  }
}

String normalizeProductSearch(String value) {
  return value
      .toLowerCase()
      .replaceAll('أ', 'ا')
      .replaceAll('إ', 'ا')
      .replaceAll('آ', 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .replaceAll('\u0640', '')
      .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u06D6-\u06ED]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double _doubleValue(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}
