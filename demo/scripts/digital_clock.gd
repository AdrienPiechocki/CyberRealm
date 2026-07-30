extends Label

var _date_format := "HH:MM, DD/mm/YYYY"
var _last_update := 0

func set_format(fmt: String) -> void:
	_date_format = fmt
	text = _format_time()

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	text = _format_time()

func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000
	if now - _last_update < 0.5:
		return
	_last_update = now
	text = _format_time()

const WEEKDAYS := ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
const MONTHS := ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

func _format_time() -> String:
	var d := Time.get_datetime_dict_from_system()
	var s := _date_format
	s = s.replace("\\n", "\n")
	s = s.replace("DDD", WEEKDAYS[d.weekday - 1])
	s = s.replace("mmm", MONTHS[d.month - 1])
	s = s.replace("YYYY", "%04d" % d.year)
	s = s.replace("YY", "%02d" % (d.year % 100))
	s = s.replace("MM", "%02d" % d.minute)
	s = s.replace("SS", "%02d" % d.second)
	var h12 = d.hour % 12
	if h12 == 0: h12 = 12
	s = s.replace("hh", "%02d" % h12)
	s = s.replace("HH", "%02d" % d.hour)
	s = s.replace("AP", "AM" if d.hour < 12 else "PM")
	s = s.replace("mm", "%02d" % d.month)
	s = s.replace("DD", "%02d" % d.day)
	return s
