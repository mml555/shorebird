// r1 — regression control: self-contained, references nothing outside itself.
// Must keep passing through the NEW pipeline (--import-dill) or the pipeline
// change itself broke something.
@pragma('dyn-module:entry-point')
String greet() => 'NEW';
