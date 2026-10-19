'use strict';
'require view';
'require form';
'require tools.widgets as widgets';

function validateUrl(section_id, value) {
	if (value == null || value === '' || /^https?:\/\/[^\s\/?#]+\S*$/.test(value))
		return true;

	return _('Expecting a http:// or https:// URL');
}

return view.extend({
	render: function() {
		let m, s, o;

		m = new form.Map('yandex-speedtest', _('Yandex speed test'),
			_('The test card is on Status → Overview. Changes apply to the next test.'));

		s = m.section(form.NamedSection, 'main', 'settings');

		o = s.option(form.Value, 'secs', _('Phase duration'),
			_('Seconds for the download and for the upload phase, 5 to 60.'));
		o.datatype = 'range(5,60)';
		o.placeholder = '15';

		o = s.option(form.Value, 'streams', _('Streams'),
			_('Parallel connections in each phase, 1 to 8.'));
		o.datatype = 'range(1,8)';
		o.placeholder = '3';

		o = s.option(widgets.NetworkSelect, 'iface', _('Interface'),
			_('Run the test through this interface. Unspecified: use the default route.'));
		o.optional = true;
		o.nocreate = true;

		o = s.option(form.Value, 'fallback_down', _('Fallback download URL'),
			_('Used when the Yandex API is unavailable. A large file, at least a few hundred megabytes.'));
		o.placeholder = 'https://speedtest.selectel.ru/1GB';
		o.validate = validateUrl;

		o = s.option(form.Value, 'fallback_up', _('Fallback upload URL'),
			_('Used when the Yandex API is unavailable. Accepts POST requests of any size.'));
		o.placeholder = 'https://speedtest.rt.ru/backend/empty.php';
		o.validate = validateUrl;

		return m.render();
	}
});
