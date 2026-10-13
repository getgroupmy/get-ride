/// Reloads the page.
void reloadWebPage() {}

/// Whether the tab is out of view.
bool webPageHidden() => false;

/// Calls [onChange] with [webPageHidden] whenever the tab is shown or
/// hidden; the returned function stops it.
void Function() onWebPageVisibility(void Function(bool hidden) onChange) => () {};
