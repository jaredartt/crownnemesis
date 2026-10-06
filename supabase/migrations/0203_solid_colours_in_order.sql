-- 0203: name colours and avatar rings -- solid colours only, one unlock order.
-- Jared: "no gradients, just solid colors. Same for profile borders", unlocking
-- Black, Red, Blue, Green, Orange, Pink, Sky blue, Purple, Brown, Gray.
-- (Applied live with execute_sql; nothing deleted, the gradient ones are just off.)
update public.skins set is_active=false, unlock_level=null, price=null
 where kind='name_color' and slug in ('nc_ember','nc_gold','nc_aurora');

update public.skins s set unlock_level=v.lvl, sort=v.srt, is_active=true, price=null
from (values ('black',1,0),('red',2,1),('blue',5,2),('green',8,3),('orange',10,4),('pink',12,5),
             ('sky',15,6),('purple',17,7),('brown',18,8)) v(slug,lvl,srt)
where s.kind='name_color' and s.slug=v.slug;
update public.skins set data='{"color":"#ff8ad1"}'::jsonb, name_es='Rosa' where kind='name_color' and slug='pink';
insert into public.skins (slug, kind, name, name_es, unlock_level, data, is_active, sort)
select 'gray','name_color','Gray','Gris',20,'{"var":"--nc-gray"}'::jsonb,true,9
where not exists (select 1 from public.skins where kind='name_color' and slug='gray');

update public.skins s set unlock_level=v.lvl, sort=v.srt, is_active=true, price=null, name_es=v.es
from (values ('frame_slate',1,30,'Negro'),('frame_red',2,31,'Rojo'),('frame_blue',5,32,'Azul'),('frame_green',8,33,'Verde'),
             ('frame_orange',10,34,'Naranja'),('frame_pink',12,35,'Rosa'),('frame_sky',15,36,'Celeste'),
             ('frame_purple',17,37,'Morado'),('frame_brown',18,38,'Castaño')) v(slug,lvl,srt,es)
where s.kind='frame' and s.slug=v.slug;
insert into public.skins (slug, kind, name, name_es, unlock_level, data, is_active, sort)
select 'frame_gray','frame','Gray ring','Gris',20,'{"ring":"#8a8a98","angle":0,"ring2":null,"ring3":null,"style":"solid"}'::jsonb,true,39
where not exists (select 1 from public.skins where kind='frame' and slug='frame_gray');
