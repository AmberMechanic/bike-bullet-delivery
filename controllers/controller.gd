extends CharacterBody3D

@onready var camera: Node3D = $Camera
@onready var collision_shape_3d: CollisionShape3D = $capsule_collider
@onready var raycast_below: RayCast3D = $RaycastBelow
@onready var rotate: Node3D = $Rotate
@onready var raycast_stairs_ahead: RayCast3D = $Rotate/RaycastStairsAhead
@onready var orig_capsule_height: float = $capsule_collider.shape.height
@onready var capsule_view_mesh: MeshInstance3D = $WorldModel/capsule_view_mesh
@onready var hat: Node3D = $WorldModel/hat
@onready var stair_climb_area: Area3D = $Rotate/stair_climb_area


@export_group("Air")
@export var air_speed_control: float = 0.075
#@export var air_cap: float = 0.85
#@export var air_accel: float = 800
#@export var air_move_speed: float = 500

@export_group("Jump")
@export var jump_velo: float = 7.0
@export var auto_bhop: bool = true
@export var jump_accel: float = 0.5
@export var jump_accel_recharge: float = 0.1
@export var jump_speedup: float = 0.05
@export var coyote_time: float = 0.1

@export_group("Climb")
@export var climb_speed: float = 3

@export_group("Crouch")
@export var cr_h_reduce: float = 0.7
@export var cr_jump_raise_scale: float = 0.9
@export var cr_walk_scale: float = 0.8

var is_crouched: bool = false

@export_group("Walk")
@export var walk_speed: float = 7.0
@export var sprint_speed: float = 10
#@export var ground_accel: float = 1.2
#@export var ground_decel: float = 0.9
@export var ground_smooth: float = 0.1
@export var ground_friction: float = 0.7

@export_group("Camera")
@export var camera_y_smooth: float = 20
@export var camera_height: float = 2

var camera_actual_height = camera_height

var wish_dir := Vector3.ZERO

var jump_recharge_inv: float = 0
var jump_recharge_inv_wgrab: float = 0
var was_on_floor_last_frame: bool = false
var speed_scale: float = 1
var coyote_timer: float = 0

var max_step_height: float = 0.5
var snapped_to_stairs_last_frame: bool = false
var pframes_since_on_floor: int = -INF

var inertial_velocity := Vector3.ZERO

var last_rotation: float = 0
var smoothed_rotation_abs_delta: float = 0

func exp_decay(a: float, b: float, d: float, delta: float) -> float:
	return b + (a - b) * exp(-d * delta)


func _ready() -> void:
	# could add automatic world model hiding here
	camera.add_raycast_exception(self)


func _process(delta: float) -> void:
	var last_y = camera.global_position.y
	camera.global_position = self.global_position
	camera.global_position.y = exp_decay(last_y, self.global_position.y + camera_actual_height, camera_y_smooth, delta)
	capsule_view_mesh.mesh.height = (orig_capsule_height - cr_h_reduce) if is_crouched else orig_capsule_height
	capsule_view_mesh.position.y = capsule_view_mesh.mesh.height * 0.5
	hat.position.y = capsule_view_mesh.mesh.height


func is_surface_too_steep(normal: Vector3) -> bool:
	return normal.angle_to(Vector3.UP) > deg_to_rad(50)

func _run_body_test_motion(from: Transform3D, motion: Vector3, result = null) -> bool:
	if not result: result = PhysicsTestMotionResult3D.new()
	var params = PhysicsTestMotionParameters3D.new()
	params.from = from
	params.motion = motion
	return PhysicsServer3D.body_test_motion(self.get_rid(), params, result)

func get_velo_at_pos(rid: RID, at: Vector3) -> Vector3:
	return PhysicsServer3D.body_get_direct_state(rid).get_velocity_at_local_position(at)

func get_collision_velo() -> Vector3:
	# get_contact_collider_velocity_at_position
	#return PhysicsServer3D.body_get_direct_state(self.get_rid()).get_contact_collider_velocity_at_position(0)
	if get_slide_collision_count() > 0:
		var avg_velo := Vector3.ZERO
		for i in range(0, get_slide_collision_count()):
			var collision = get_slide_collision(i)
			var avg_velo_for_collision := Vector3.ZERO
			for j in range(0, collision.get_collision_count()):
				avg_velo_for_collision += get_velo_at_pos(collision.get_collider_rid(j), collision.get_position(j))
			avg_velo_for_collision /= collision.get_collision_count()
			avg_velo += avg_velo_for_collision
		avg_velo /= get_slide_collision_count()
		return avg_velo
	else:
		return Vector3.ZERO

func get_move_speed() -> float:
	var res = walk_speed
	if Input.is_action_pressed("crouch"):
		res *= cr_walk_scale
	else:
		if Input.is_action_pressed("sprint"):
			res = sprint_speed
	return speed_scale * res

func _air_physics_process(delta: float) -> void:
	self.velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	# my take on movement in air
	var speed = get_move_speed()
	self.velocity -= inertial_velocity
	self.velocity.x = lerp(self.velocity.x, wish_dir.x * speed, air_speed_control)
	self.velocity.z = lerp(self.velocity.z, wish_dir.z * speed, air_speed_control)
	self.velocity += inertial_velocity
	# tutorial's take on movement in air, from source/quake. feels too rigid, stopping immediately in the air, immediately changing direction
	#var cur_speed_in_air_wish_dir = self.velocity.dot(wish_dir)
	#var capped_speed = min((air_move_speed * wish_dir).length(), air_cap)
	#var add_speed_until_cap = capped_speed - cur_speed_in_air_wish_dir
	#if add_speed_until_cap > 0:
		#var accel_speed = air_accel * air_move_speed * delta
		#accel_speed = min(accel_speed, add_speed_until_cap)
		#self.velocity += accel_speed * wish_dir

func _walkrun_physics_process(delta: float) -> void:
	var speed = get_move_speed() # * delta
	#self.velocity.x = wish_dir.x * speed
	#self.velocity.z = wish_dir.z * speed
	var y_vel = self.velocity.y
	var xz_vel = Vector3(1, 0, 1) * self.velocity
	var vel_norm = xz_vel.normalized()
	#var along_vel = vel_norm.dot(wish_dir.normalized()) * self.velocity * speed # * wish_dir.length() # project wish_dir onto velocity vec
	#var aside = wish_dir - along_vel
	#if along_vel.length() > 0:
		#along_vel *= ground_accel
	#else:
		#along_vel *= ground_decel
	#var new_wish_dir = along_vel + aside
	xz_vel = lerp(xz_vel, wish_dir * speed, ground_smooth) # * xz_vel.length()
	if xz_vel.length() > speed:
		var over = xz_vel.length() - speed
		xz_vel = (over * ground_friction + speed) * xz_vel.normalized()
	self.velocity = xz_vel
	self.velocity.y = y_vel

func _crouch_physics_process(delta: float) -> void:
	pass

func _snap_down_to_stairs_check() -> void:
	var did_snap: bool = false
	var floor_below: bool = raycast_below.is_colliding() and not is_surface_too_steep(raycast_below.get_collision_normal())
	var flew_off_this_frame: bool = pframes_since_on_floor == 1
	if not is_on_floor() and velocity.y <= 0 and (flew_off_this_frame or snapped_to_stairs_last_frame) and floor_below:
		var body_test_result = PhysicsTestMotionResult3D.new()
		if _run_body_test_motion(self.global_transform, Vector3(0, -max_step_height, 0), body_test_result):
			var translate_y = body_test_result.get_travel().y
			self.position.y += translate_y
			apply_floor_snap()
			did_snap = true
	snapped_to_stairs_last_frame = did_snap

func _snap_up_stairs_check(delta: float) -> bool:
	if not is_on_floor() and not snapped_to_stairs_last_frame:
		# snapped_to_stairs_last_frame = false
		return false
	var expected_move_motion = self.velocity * Vector3(1,0,1) * delta
	var step_pos_with_clearance = self.global_transform.translated(expected_move_motion + Vector3(0, max_step_height * 2, 0))
	var down_check_result = PhysicsTestMotionResult3D.new()
	if _run_body_test_motion(step_pos_with_clearance, Vector3(0, max_step_height * -2, 0), down_check_result):
		var collider = down_check_result.get_collider()
		if collider.is_class("StaticBody3D") or collider.is_class("CSGShape3D"):
			var step_height = ((step_pos_with_clearance.origin + down_check_result.get_travel()) - self.global_position).y
			if step_height > max_step_height or step_height < 0.01 or (down_check_result.get_collision_point() - self.global_position).y > max_step_height:
				#snapped_to_stairs_last_frame = false
				return false
			raycast_stairs_ahead.global_position = (down_check_result.get_collision_point() + Vector3(0, max_step_height, 0) + expected_move_motion.normalized() * 0.1)
			raycast_stairs_ahead.force_raycast_update()
			if raycast_stairs_ahead.is_colliding() and not is_surface_too_steep(raycast_stairs_ahead.get_collision_normal()):
				var last_pos = self.global_position
				self.global_position = step_pos_with_clearance.origin + down_check_result.get_travel()
				#var new_pos = step_pos_with_clearance.origin + down_check_result.get_travel()
				#if new_pos.y - last_pos.y > 1:
					#self.global_position = new_pos
					#self.global_position.y = last_pos + 1
				#else:
					#self.global_position = new_pos
				apply_floor_snap()
				snapped_to_stairs_last_frame = true
				return true
	#snapped_to_stairs_last_frame = false
	return false

func _handle_crouch(delta: float) -> void:
	var was_crouched_last_frame: bool = is_crouched
	if Input.is_action_pressed("crouch"):
		is_crouched = true
	elif is_crouched and not self.test_move(self.global_transform, Vector3(0, cr_h_reduce, 0)):
		is_crouched = false
	# cr_h_reduce * cr_jump_raise_scale
	
	var translate_y_if_possible: float = 0
	if was_crouched_last_frame != is_crouched and not is_on_floor() and not snapped_to_stairs_last_frame:
		translate_y_if_possible = cr_h_reduce * cr_jump_raise_scale * (1 if is_crouched else -1)
	
	if translate_y_if_possible != 0:
		var result = KinematicCollision3D.new()
		self.test_move(self.global_transform, Vector3(0, translate_y_if_possible, 0), result)
		self.position.y += result.get_travel().y
	
	camera_actual_height = camera_height - cr_h_reduce if is_crouched else camera_height
	collision_shape_3d.shape.height = (orig_capsule_height - cr_h_reduce) if is_crouched else orig_capsule_height
	collision_shape_3d.position.y = collision_shape_3d.shape.height * 0.5

func _physics_process(delta: float) -> void:
	rotate.basis = camera.nodeRotate.basis
	var input_dir: Vector2 = Input.get_vector("left", "right", "up", "down").normalized()
	wish_dir = camera.nodeRotate.basis * Vector3(input_dir.x, 0.0, input_dir.y)
	var was_on_floor_at_start_of_frame: bool = is_on_floor()
	var did_jump: bool = false
	
	
	_handle_crouch(delta)
	
	if was_on_floor_at_start_of_frame:
		coyote_timer = 0
	
	if (coyote_timer <= coyote_time) or was_on_floor_at_start_of_frame or snapped_to_stairs_last_frame:
		if (coyote_timer <= coyote_time) and not is_on_floor():
			self.velocity.y *= 0.5
		if (auto_bhop and Input.is_action_pressed("jump")) or Input.is_action_just_pressed("jump"):
			#if not was_on_floor_last_frame:
				#speed_scale += jump_speedup
			#else:
				#speed_scale = 1
			did_jump = true
			self.velocity.y = 0 # otherwise jumping in coyote time seems very weak
			var y_jump: float = jump_velo * (1 - jump_recharge_inv)
			if not (was_on_floor_at_start_of_frame or snapped_to_stairs_last_frame):
				self.velocity += Vector3(0, y_jump, 0)
			else:
				self.velocity += get_floor_normal() * y_jump
			#inertial_velocity = get_collision_velo()
			var actual_jump_accel = jump_accel * (1 - jump_recharge_inv) * speed_scale
			self.velocity.x = self.velocity.x + self.velocity.x * actual_jump_accel
			self.velocity.z = self.velocity.z + self.velocity.z * actual_jump_accel
			jump_recharge_inv = 1 # lerp(jump_recharge_inv, 1.0, 0.5)
			coyote_timer = coyote_time
	if was_on_floor_at_start_of_frame or snapped_to_stairs_last_frame: # after implementing crouching, switch based on crouch state
		_walkrun_physics_process(delta)
		#floor_max_angle = deg_to_rad(50)
		pframes_since_on_floor = 0
		#was_on_floor_last_frame = true
		jump_recharge_inv_wgrab = 0
		if not did_jump:
			inertial_velocity = lerp(inertial_velocity, get_collision_velo(), 0.10)
		else:
			inertial_velocity = lerp(inertial_velocity, get_collision_velo(), 0.01)
	else:
		floor_max_angle = deg_to_rad(80)
		_air_physics_process(delta)
		#self.velocity += ground_velo
		pframes_since_on_floor += 1
		#was_on_floor_last_frame = false
	
	#it would be nice to have some better way of combining forward and up movement. it should probably be mainly up, but forward would be super cool for wall jumping
	if stair_climb_area.has_overlapping_bodies():
		#if Input.is_action_just_pressed("jump"):
		if Input.is_action_pressed("jump"):
			self.velocity *= Vector3(0, 0.5, 0.5)
			self.velocity += (climb_speed * Vector3.UP)
			jump_recharge_inv = 0
	if not _snap_up_stairs_check(delta):
		move_and_slide()
		_snap_down_to_stairs_check()
	else:
		self.velocity.y = 0 # prevents jump accumulating during stair up snapping
	
	
	var turn_amount = camera.nodeRotate.basis.get_euler().y - last_rotation
	smoothed_rotation_abs_delta = lerp(smoothed_rotation_abs_delta, abs(turn_amount), 0.1)
	var turn_speed_inv: float = 0.1 / (smoothed_rotation_abs_delta + 0.0000001)
	var vel_turn_factor: float = 1 - (1 / (1 + turn_speed_inv))
	vel_turn_factor *= vel_turn_factor
	#print(vel_turn_factor)
	
	var velo_no_y = self.velocity * Vector3(1, 0, 1)
	
	#var vel_len: float = velo_no_y.length()
	#var vel_norm: Vector3 = velo_no_y.normalized()
	#var vel_norm_rot: Vector3 = vel_norm.rotated(Vector3.UP, turn_amount)
	##var vel_norm_rot: Vector3 = camera.nodeRotate.basis * vel_norm
	#velo_no_y = lerp(vel_norm, vel_norm_rot, vel_turn_factor).normalized() * vel_len
	#self.velocity = velo_no_y + Vector3(0, self.velocity.y, 0)
	
	var ine_vel_len: float = inertial_velocity.length() * min(1, 0.02 * vel_turn_factor + 0.99)
	var ine_vel_norm: Vector3 = inertial_velocity.normalized()
	var ine_vel_norm_rot: Vector3 = ine_vel_norm.rotated(Vector3.UP, turn_amount) # either seems to turn too little or too much
	#var ine_vel_norm_rot: Vector3 = camera.nodeRotate.basis * ine_vel_norm
	inertial_velocity = lerp(ine_vel_norm, ine_vel_norm_rot, vel_turn_factor).normalized() * ine_vel_len
	
	last_rotation = camera.nodeRotate.basis.get_euler().y
	
	if inertial_velocity.length() > 0.0001:
		camera.vector_pointer.look_at(camera.hold_position.global_position + inertial_velocity)
	camera.vector_pointer.scale.z = inertial_velocity.length()
	
	
	floor_max_angle = deg_to_rad(50 + 45 * (1 - (1 / ((self.velocity * Vector3(1, 0, 1)).length() * 0.1 + 1))))
	jump_recharge_inv *= 1 - jump_accel_recharge
	coyote_timer += delta

# fall prevention (crouching or in some areas)

# detect nearby ledges with a line of raycasts in the movement direction (maybe spaced out more at higher speeds)
# if not jumping (also implement coyote time with raycaststairsbelow, maybe rename that), calculate at each's angle what a flat plane's distance would be
# if the distance exceeds that projected plane, at any spot, find the closest drop, and concentrate the stack to focus on that for a better distance estimate
# apply a force to slow the player down, but if the player is moving sideways to it, turn their movement vector instead

# alternatively, have 8 invisible colliders around the player each with their own raycast
# when their distance is within some margin of the player's foot position, move them outwards up to some maximum distance
# if their distance indicates a drop off, use the players movement delta to update the new position (if the player moves +z a units towards a dropoff, the +z wall moves relatively -a, and the diagonal +z walls move `sqrt(2*a*a)`)
# the player will then collide with the walls and no longer fall off
# this however is very absolute, rather than a more invisible nudge
