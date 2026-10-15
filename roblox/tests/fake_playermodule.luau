local controls = { enabled = true }
function controls:Enable()
	self.enabled = true
end
function controls:Disable()
	self.enabled = false
end
return {
	GetControls = function()
		return controls
	end,
}
