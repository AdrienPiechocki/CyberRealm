extends Node3D
## Stub minimal du player pour les tests de focus_mode : enter_focus écrit
## `player.focus_mode_active = true` à la première entrée, il faut donc un
## objet réel (le vrai player.gd dépend de l'arbre de scène complet).

var focus_mode_active := false
var locked := false