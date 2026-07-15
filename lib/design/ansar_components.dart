import 'package:flutter/material.dart';

import 'ansar_tokens.dart';

class AnsarPageHeader extends StatelessWidget {
  const AnsarPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.action,
    this.badge,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget? action;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: ansarSpace16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: successSurface,
              borderRadius: BorderRadius.circular(ansarRadius),
            ),
            child: Icon(icon, color: brandColor, size: 23),
          ),
          const SizedBox(width: ansarSpace12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
                    if (badge != null) ...[
                      const SizedBox(width: ansarSpace8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: warningSurface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: accentColor.withValues(alpha: 0.35)),
                        ),
                        child: Text(
                          badge!,
                          style: const TextStyle(color: warningColor, fontSize: 10, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: ansarSpace4),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: ansarSpace8),
            action!,
          ],
        ],
      ),
    );
  }
}

class AnsarMetricCard extends StatelessWidget {
  const AnsarMetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.caption,
  });

  final String label;
  final String value;
  final String? caption;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(ansarSpace12),
      decoration: BoxDecoration(
        color: panelSurface,
        borderRadius: BorderRadius.circular(ansarRadius),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(ansarRadius),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const Spacer(),
              Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: ansarSpace8),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
          if (caption != null)
            Text(caption!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class AnsarFilterSummary extends StatelessWidget {
  const AnsarFilterSummary({
    super.key,
    required this.labels,
    required this.onTap,
    this.title = 'نطاق العرض',
  });

  final String title;
  final List<String> labels;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: panelSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ansarRadius),
        side: const BorderSide(color: borderColor),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ansarRadius),
        child: Padding(
          padding: const EdgeInsets.all(ansarSpace12),
          child: Row(
            children: [
              const Icon(Icons.tune_rounded, color: brandColor),
              const SizedBox(width: ansarSpace12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: ansarSpace4),
                    Text(labels.join('  •  '), maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left_rounded, color: mutedInk),
            ],
          ),
        ),
      ),
    );
  }
}

class AnsarSkeleton extends StatefulWidget {
  const AnsarSkeleton({super.key, this.rows = 5});

  final int rows;

  @override
  State<AnsarSkeleton> createState() => _AnsarSkeletonState();
}

class _AnsarSkeletonState extends State<AnsarSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final color = Color.lerp(const Color(0xffE7ECE9), const Color(0xffF3F6F4), controller.value)!;
        return ListView.separated(
          padding: pagePadding,
          itemCount: widget.rows,
          separatorBuilder: (_, __) => const SizedBox(height: ansarSpace12),
          itemBuilder: (context, index) => Container(
            height: index == 0 ? 72 : 94,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(ansarRadius)),
          ),
        );
      },
    );
  }
}

class AnsarInlineNotice extends StatelessWidget {
  const AnsarInlineNotice({super.key, required this.message, this.icon = Icons.info_outline_rounded});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: ansarSpace12, vertical: 10),
      decoration: BoxDecoration(
        color: infoSurface,
        borderRadius: BorderRadius.circular(ansarRadius),
        border: Border.all(color: infoColor.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, color: infoColor, size: 19),
          const SizedBox(width: ansarSpace8),
          Expanded(child: Text(message, style: const TextStyle(color: infoColor, fontSize: 12, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
