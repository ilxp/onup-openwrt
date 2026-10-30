-- Copyright (C) 2026 ilxp <https://github.com/ilxp>

rt_log = SimpleForm("onup")
rt_log.reset = false
rt_log.submit = false
rt_log:append(Template("onup/rt_log"))

return rt_log
