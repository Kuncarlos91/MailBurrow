import 'package:flutter/material.dart';

Future<int?> showArchivePagePicker(
  BuildContext context, {
  required int currentPage,
  required int totalPages,
}) => showDialog<int>(
  context: context,
  builder: (_) => _PagePicker(currentPage: currentPage, totalPages: totalPages),
);

class _PagePicker extends StatefulWidget {
  const _PagePicker({required this.currentPage, required this.totalPages});
  final int currentPage, totalPages;
  @override
  State<_PagePicker> createState() => _PagePickerState();
}

class _PagePickerState extends State<_PagePicker> {
  late final TextEditingController input;
  String? error;

  @override
  void initState() {
    super.initState();
    input = TextEditingController(text: '${widget.currentPage}');
    input.selection = TextSelection(
      baseOffset: 0,
      extentOffset: input.text.length,
    );
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void submit() {
    final page = int.tryParse(input.text.trim());
    if (page == null || page < 1 || page > widget.totalPages) {
      setState(() => error = 'Enter a page from 1 to ${widget.totalPages}.');
      return;
    }
    Navigator.pop(context, page);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Go to page'),
    scrollable: true,
    content: TextField(
      controller: input,
      autofocus: true,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: 12,
      decoration: InputDecoration(
        labelText: 'Page number',
        helperText: '1 to ${widget.totalPages}',
        helperMaxLines: 2,
        errorMaxLines: 3,
        errorText: error,
        counterText: '',
      ),
      onChanged: (_) {
        if (error != null) setState(() => error = null);
      },
      onSubmitted: (_) => submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: submit, child: const Text('Go')),
    ],
  );
}
