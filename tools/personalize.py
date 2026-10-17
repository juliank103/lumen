"""Fills the placeholders with this build's settings from Actions secrets (neutral defaults if unset)."""
import io, os
values = {
    '__HOME_QUERY__': os.environ.get('HOME_QUERY') or '',
    '__HOME_NAME__': os.environ.get('HOME_NAME') or 'Home base',
    '__AREA_LAT__': os.environ.get('AREA_LAT') or '39.83',
    '__AREA_LON__': os.environ.get('AREA_LON') or '-98.58',
    '__APP_FULL__': os.environ.get('APP_FULL') or 'Lumen',
    '__APP_NAME__': os.environ.get('APP_NAME') or 'Lumen',
    '__APP_SLUG__': os.environ.get('APP_SLUG') or 'lumen',
}
for top in ('ios', 'core'):
    for root, _, names in os.walk(top):
        for name in names:
            if not name.endswith(('.swift', '.js', '.json', '.plist')):
                continue
            path = os.path.join(root, name)
            text = io.open(path, encoding='utf-8').read()
            new = text
            for key, value in values.items():
                new = new.replace(key, value)
            if new != text:
                io.open(path, 'w', encoding='utf-8', newline='\n').write(new)
print('ok')
