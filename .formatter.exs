[
  import_deps: [:phoenix],
  plugins: [Quokka, Phoenix.LiveView.HTMLFormatter],
  autosort: [:defstruct, :schema],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}"]
]
