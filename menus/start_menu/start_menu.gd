extends Control
#trail color e99039
@onready var start_button = $VBoxContainer/StartButton
@onready var credits_button = $VBoxContainer/CreditsButton
@onready var quit_button = $VBoxContainer/QuitButton

func _ready():
	# Make sure cursor is visible in the start menu
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	start_button.pressed.connect(_on_start_pressed)
	credits_button.pressed.connect(_on_credits_pressed)
	quit_button.pressed.connect(_on_quit_pressed)

func _on_start_pressed():
	get_tree().change_scene_to_file("res://cutscenes/slideshow/slideshow.tscn")

func _on_options_pressed():
	# TODO: Implement options menu
	pass

func _on_credits_pressed():
	get_tree().change_scene_to_file("res://menus/credits/credits.tscn")

func _on_quit_pressed():
	get_tree().quit()
