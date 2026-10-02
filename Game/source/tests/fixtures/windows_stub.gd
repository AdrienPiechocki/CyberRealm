extends Node3D
## Stub de `windows_3d.gd` pour les tests du mode focus. `focus_mode.gd` ne lit
## que ces deux tables du gestionnaire de fenêtres ; le vrai script dépend du
## compositeur Wayland et ne s'instancie pas en headless.

var window_titles: Dictionary = {}
var window_server_side: Dictionary = {}