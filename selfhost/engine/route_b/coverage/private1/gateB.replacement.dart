import 'package:flutter/foundation.dart';
import 'package:wonders/common_libs.dart';
import 'package:wonders/ui/common/app_icons.dart';
import 'package:wonders/ui/common/ignore_pointer.dart';
import 'package:wonders/ui/common/controls/buttons.dart';

@pragma('dyn-module:entry-point')
@override
  Widget build(AppBtn self, BuildContext context) {
    Color defaultColor = self.isSecondary ? $styles.colors.white : $styles.colors.greyStrong;
    Color textColor = self.isSecondary ? $styles.colors.black : $styles.colors.white;
    BorderSide side = self.border ?? BorderSide.none;

    Widget content = self._builder?.call(context) ?? self.child ?? SizedBox.shrink();
    if (self.expand) content = Center(child: content);

    OutlinedBorder shape = self.circular
        ? CircleBorder(side: side)
        : RoundedRectangleBorder(side: side, borderRadius: BorderRadius.circular($styles.corners.md));

    ButtonStyle style = ButtonStyle(
      minimumSize: ButtonStyleButton.allOrNull<Size>(self.minimumSize ?? Size.zero),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      splashFactory: NoSplash.splashFactory,
      backgroundColor: ButtonStyleButton.allOrNull<Color>(self.bgColor ?? defaultColor),
      overlayColor: ButtonStyleButton.allOrNull<Color>(Colors.transparent), // disable default press effect
      shape: ButtonStyleButton.allOrNull<OutlinedBorder>(shape),
      padding: ButtonStyleButton.allOrNull<EdgeInsetsGeometry>(self.padding ?? EdgeInsets.all($styles.insets.md)),

      enableFeedback: self.enableFeedback,
    );

    Widget button = _CustomFocusBuilder(
      focusNode: self.focusNode,
      onFocusChanged: self.onFocusChanged,
      builder: (context, focus) => Stack(
        children: [
          Opacity(
            opacity: self.onPressed == null ? 0.5 : 1.0,
            child: TextButton(
              onPressed: self.onPressed,
              style: style,
              focusNode: focus,
              child: DefaultTextStyle(
                style: DefaultTextStyle.of(context).style.copyWith(color: textColor),
                child: content,
              ),
            ),
          ),
          if (focus.hasFocus)
            Positioned.fill(
              child: IgnorePointerAndSemantics(
                child: Container(
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular($styles.corners.md),
                        border: Border.all(color: $styles.colors.accent1, width: 3))),
              ),
            )
        ],
      ),
    );

    // add press effect:
    if (self.pressEffect && self.onPressed != null) button = _ButtonPressEffect(button);
    if (self.hoverEffect && kIsWeb) button = _ButtonHoverEffect(button, self.circular);

    // add semantics?
    if (self.semanticLabel.isEmpty) return button;
    return Semantics(
      label: self.semanticLabel,
      button: true,
      container: true,
      onTap: () => self.onPressed?.call(),
      child: ExcludeSemantics(child: button),
    );
  }
