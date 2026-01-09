local signals = require "nightfury/signals/main"

function data()
	return {
		info = {
			name = _("better_signals_name"),
			description = _("better_signals_desc"),
			minorVersion = 0,
			modid = "nightfury34_better_signals_1",
			severityAdd = "NONE",
			severityRemove = "WARNING",
			authors = {
				{
					name = "nightfury34",
					role = "CREATOR",
				},
			},
			params = {
				{
					key = "better_signals_view_distance",
					name = _("better_signals_view_distance"),
					uiType = "SLIDER",
					values = {  _("500"), _("1000"), _("1500"), _("2000"), _("2500"), _("3000"), },
					tooltip = _("better_signals_view_distance_tooltip"),
					defaultIndex = 4,
				  },
			},
		},
		runFn = function(settings, modParams)
			if modParams[getCurrentModId()] ~= nil then
				local params = modParams[getCurrentModId()]
				
				if params["better_signals_view_distance"] ~= nil then
					-- Support old values - default to 2000
					if params["better_signals_view_distance"] > 6 then
						signals.viewDistance = 2000
					else
						signals.viewDistance = (params["better_signals_view_distance"]+1) * 500
					end
				end
			end

			signals.signals['default'] = {
				type = "main",
				isAnimated = false
			}
		end,
	}
end