-- ============================================================
-- SISTEMA DE INVENTARIO DE DONACIONES - COLEGIO EDUARDO BLANCO
-- Script completo con soporte para excedentes públicos
-- ============================================================

-- 1. EXTENSIONES
-- ============================================================
create extension if not exists "uuid-ossp";

-- 2. TIPOS ENUM
-- ============================================================
drop type if exists user_role cascade;
create type user_role as enum ('admin', 'usuario');

drop type if exists estado_solicitud cascade;
create type estado_solicitud as enum ('activa', 'parcialmente_cubierta', 'resuelta', 'cancelada');

drop type if exists prioridad_solicitud cascade;
create type prioridad_solicitud as enum ('baja', 'media', 'alta', 'urgente');

-- ============================================================
-- 3. TABLAS PRINCIPALES
-- ============================================================

-- PROFILES (extiende auth.users)
-- ============================================================
drop table if exists public.historial_donaciones cascade;
drop table if exists public.solicitudes cascade;
drop table if exists public.donaciones cascade;
drop table if exists public.productos cascade;
drop table if exists public.categorias cascade;
drop table if exists public.profiles cascade;

create table public.profiles (
  id uuid references auth.users(id) on delete cascade primary key,
  email text unique not null,
  nombre_completo text,
  rol user_role default 'usuario' not null,
  avatar_url text,
  centro_asociado text, -- Nombre del centro de acopio al que pertenece
  created_at timestamp with time zone default timezone('utc', now()) not null,
  updated_at timestamp with time zone default timezone('utc', now()) not null
);

comment on table public.profiles is 'Perfiles de usuario con roles y centro asociado';

-- CATEGORIAS
-- ============================================================
create table public.categorias (
  id uuid default uuid_generate_v4() primary key,
  nombre text not null unique,
  emoji text default '📦',
  color text default 'blue',
  es_fija boolean default false,
  activa boolean default true,
  creado_por uuid references public.profiles(id) on delete set null,
  created_at timestamp with time zone default timezone('utc', now()) not null,
  updated_at timestamp with time zone default timezone('utc', now()) not null
);

comment on table public.categorias is 'Categorías de productos';

-- PRODUCTOS (con campo es_excedente)
-- ============================================================
create table public.productos (
  id uuid default uuid_generate_v4() primary key,
  categoria_id uuid references public.categorias(id) on delete cascade not null,
  nombre text not null,
  es_fijo boolean default false,
  es_excedente boolean default false, -- 🆕 Indica si hay exceso de este producto
  cantidad_excedente integer default 0, -- 🆕 Cantidad aproximada en exceso
  activo boolean default true,
  creado_por uuid references public.profiles(id) on delete set null,
  created_at timestamp with time zone default timezone('utc', now()) not null,
  updated_at timestamp with time zone default timezone('utc', now()) not null,
  unique(categoria_id, nombre)
);

comment on column public.productos.es_excedente is 'Indica si el producto está en exceso y disponible para otros centros';
comment on column public.productos.cantidad_excedente is 'Cantidad aproximada disponible en exceso';

create index idx_productos_categoria on public.productos(categoria_id);
create index idx_productos_excedente on public.productos(es_excedente) where es_excedente = true;

-- DONACIONES
-- ============================================================
create table public.donaciones (
  id uuid default uuid_generate_v4() primary key,
  categoria_id uuid references public.categorias(id) on delete restrict not null,
  producto_id uuid references public.productos(id) on delete restrict,
  producto_nombre text not null,
  
  -- Campos específicos para ROPA
  tipo_prenda text,
  sexo text,
  edad text,
  talla text,
  detalles jsonb default '{}'::jsonb,
  
  -- Datos de la donación
  cantidad integer not null check (cantidad > 0),
  unidad text not null default 'unidades',
  donante text not null,
  notas text,
  imagen_url text,
  
  -- Metadatos
  fecha_donacion timestamp with time zone default timezone('utc', now()) not null,
  creado_por uuid references public.profiles(id) on delete set null not null,
  created_at timestamp with time zone default timezone('utc', now()) not null,
  updated_at timestamp with time zone default timezone('utc', now()) not null
);

comment on table public.donaciones is 'Registro principal de donaciones recibidas';

create index idx_donaciones_categoria on public.donaciones(categoria_id);
create index idx_donaciones_producto on public.donaciones(producto_id);
create index idx_donaciones_donante on public.donaciones(donante);
create index idx_donaciones_fecha on public.donaciones(fecha_donacion desc);

-- SOLICITUDES
-- ============================================================
create table public.solicitudes (
  id uuid default uuid_generate_v4() primary key,
  categoria_id uuid references public.categorias(id) on delete restrict not null,
  producto_id uuid references public.productos(id) on delete set null,
  producto_nombre text not null,
  
  -- Detalles específicos
  tipo_prenda text,
  sexo text,
  edad text,
  talla text,
  detalles jsonb default '{}'::jsonb,
  
  -- Información de la solicitud
  cantidad_necesaria integer not null check (cantidad_necesaria > 0),
  cantidad_recibida integer default 0,
  unidad text not null default 'unidades',
  prioridad prioridad_solicitud default 'media' not null,
  descripcion text,
  
  -- Información del centro solicitante
  centro_solicitante text not null,
  ubicacion text,
  contacto_nombre text,
  contacto_telefono text,
  contacto_email text,
  
  -- Estado
  estado estado_solicitud default 'activa' not null,
  
  -- Fechas
  fecha_solicitud timestamp with time zone default timezone('utc', now()) not null,
  fecha_limite timestamp with time zone,
  creado_por uuid references public.profiles(id) on delete set null not null,
  created_at timestamp with time zone default timezone('utc', now()) not null,
  updated_at timestamp with time zone default timezone('utc', now()) not null
);

comment on table public.solicitudes is 'Solicitudes de productos que los centros necesitan';

create index idx_solicitudes_categoria on public.solicitudes(categoria_id);
create index idx_solicitudes_producto on public.solicitudes(producto_id);
create index idx_solicitudes_estado on public.solicitudes(estado);
create index idx_solicitudes_prioridad on public.solicitudes(prioridad);
create index idx_solicitudes_fecha on public.solicitudes(fecha_solicitud desc);

-- HISTORIAL
-- ============================================================
create table public.historial_donaciones (
  id uuid default uuid_generate_v4() primary key,
  donacion_id uuid not null,
  accion text not null,
  datos_anteriores jsonb,
  datos_nuevos jsonb,
  usuario_id uuid references public.profiles(id) on delete set null,
  created_at timestamp with time zone default timezone('utc', now()) not null
);

create index idx_historial_donacion on public.historial_donaciones(donacion_id);

-- ============================================================
-- 4. FUNCIONES Y TRIGGERS
-- ============================================================

-- Función: actualizar updated_at
-- ============================================================
create or replace function public.actualizar_updated_at()
returns trigger as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$ language plpgsql;

-- Función: crear profile al registrarse
-- ============================================================
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email, nombre_completo, rol)
  values (
    new.id,
    new.email,
    coalesce(
      new.raw_user_meta_data->>'nombre_completo', 
      new.raw_user_meta_data->>'full_name', 
      split_part(new.email, '@', 1)
    ),
    coalesce((new.raw_user_meta_data->>'rol')::user_role, 'usuario'::user_role)
  );
  return new;
end;
$$ language plpgsql security definer;

-- Trigger: crear profile al registrar usuario
-- ============================================================
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Triggers: updated_at en todas las tablas
-- ============================================================
create trigger set_updated_at before update on public.profiles
  for each row execute procedure public.actualizar_updated_at();

create trigger set_updated_at before update on public.categorias
  for each row execute procedure public.actualizar_updated_at();

create trigger set_updated_at before update on public.productos
  for each row execute procedure public.actualizar_updated_at();

create trigger set_updated_at before update on public.donaciones
  for each row execute procedure public.actualizar_updated_at();

create trigger set_updated_at before update on public.solicitudes
  for each row execute procedure public.actualizar_updated_at();

-- Función: obtener rol del usuario
-- ============================================================
create or replace function public.obtener_rol_usuario()
returns user_role as $$
  select rol from public.profiles where id = auth.uid();
$$ language sql security definer stable;

-- Función: verificar si es admin
-- ============================================================
create or replace function public.es_admin()
returns boolean as $$
  select rol = 'admin' from public.profiles where id = auth.uid();
$$ language sql security definer stable;

-- 🆕 Función: actualizar solicitudes automáticamente al registrar donación
-- ============================================================
create or replace function public.actualizar_estado_solicitud()
returns trigger as $$
begin
  if TG_OP = 'INSERT' then
    update public.solicitudes
    set 
      cantidad_recibida = least(cantidad_recibida + NEW.cantidad, cantidad_necesaria),
      estado = case 
        when least(cantidad_recibida + NEW.cantidad, cantidad_necesaria) >= cantidad_necesaria then 'resuelta'::estado_solicitud
        when cantidad_recibida + NEW.cantidad > 0 then 'parcialmente_cubierta'::estado_solicitud
        else estado
      end,
      updated_at = timezone('utc', now())
    where 
      (producto_id = NEW.producto_id or producto_id is null)
      and categoria_id = NEW.categoria_id
      and estado in ('activa'::estado_solicitud, 'parcialmente_cubierta'::estado_solicitud);
  end if;
  
  return NEW;
end;
$$ language plpgsql security definer;

drop trigger if exists trigger_actualizar_solicitudes on public.donaciones;
create trigger trigger_actualizar_solicitudes
  after insert on public.donaciones
  for each row execute procedure public.actualizar_estado_solicitud();

-- ============================================================
-- 5. ROW LEVEL SECURITY (RLS)
-- ============================================================

alter table public.profiles enable row level security;
alter table public.categorias enable row level security;
alter table public.productos enable row level security;
alter table public.donaciones enable row level security;
alter table public.solicitudes enable row level security;
alter table public.historial_donaciones enable row level security;

-- --- PROFILES ---
create policy "profiles_select_all" on public.profiles
  for select using (auth.role() = 'authenticated');

create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id);

-- --- CATEGORIAS ---
-- 🆕 Acceso público a categorías activas (para solicitudes.html sin login)
create policy "categorias_select_public" on public.categorias
  for select using (activa = true);

create policy "categorias_insert_admin" on public.categorias
  for insert with check (public.es_admin());

create policy "categorias_update_admin" on public.categorias
  for update using (public.es_admin());

create policy "categorias_delete_admin" on public.categorias
  for delete using (public.es_admin());

-- --- PRODUCTOS ---
-- 🆕 Acceso público a productos activos (necesario para solicitudes)
create policy "productos_select_public" on public.productos
  for select using (activo = true);

--  Acceso público a productos excedentes (cualquiera puede verlos)
create policy "productos_excedentes_public" on public.productos
  for select using (es_excedente = true);

create policy "productos_insert_admin" on public.productos
  for insert with check (public.es_admin());

create policy "productos_update_admin" on public.productos
  for update using (public.es_admin());

create policy "productos_delete_admin" on public.productos
  for delete using (public.es_admin());

-- --- DONACIONES ---
create policy "donaciones_select_auth" on public.donaciones
  for select using (auth.role() = 'authenticated');

create policy "donaciones_insert_auth" on public.donaciones
  for insert with check (auth.role() = 'authenticated');

create policy "donaciones_update_admin" on public.donaciones
  for update using (public.es_admin());

create policy "donaciones_delete_admin" on public.donaciones
  for delete using (public.es_admin());

-- --- SOLICITUDES ---
--  Acceso público a solicitudes (para que cualquiera pueda ver qué se necesita)
create policy "solicitudes_select_public" on public.solicitudes
  for select using (true);

create policy "solicitudes_insert_auth" on public.solicitudes
  for insert with check (auth.role() = 'authenticated');

create policy "solicitudes_update_own" on public.solicitudes
  for update using (auth.uid() = creado_por or public.es_admin());

create policy "solicitudes_delete_own" on public.solicitudes
  for delete using (auth.uid() = creado_por or public.es_admin());

-- --- HISTORIAL ---
create policy "historial_select_admin" on public.historial_donaciones
  for select using (public.es_admin());

create policy "historial_insert_system" on public.historial_donaciones
  for insert with check (true);

-- ============================================================
-- 6. VISTAS
-- ============================================================

-- Vista: resumen por categoría
-- ============================================================
create or replace view public.vista_resumen_categorias as
select 
  c.id as categoria_id,
  c.nombre,
  c.emoji,
  c.color,
  count(d.id) as total_registros,
  coalesce(sum(d.cantidad), 0) as total_unidades,
  count(distinct d.donante) as total_donantes
from public.categorias c
left join public.donaciones d on d.categoria_id = c.id
where c.activa = true
group by c.id, c.nombre, c.emoji, c.color;

-- Vista: últimas donaciones
-- ============================================================
create or replace view public.vista_ultimas_donaciones as
select 
  d.id,
  d.producto_nombre,
  d.cantidad,
  d.unidad,
  d.donante,
  d.fecha_donacion,
  c.nombre as categoria_nombre,
  c.emoji as categoria_emoji,
  c.color as categoria_color
from public.donaciones d
join public.categorias c on c.id = d.categoria_id
order by d.fecha_donacion desc
limit 20;

--  Vista: productos excedentes (PÚBLICA - sin autenticación)
-- ============================================================
create or replace view public.vista_excedentes_publicos as
select 
  p.id as producto_id,
  p.nombre as producto_nombre,
  p.cantidad_excedente,
  c.id as categoria_id,
  c.nombre as categoria_nombre,
  c.emoji as categoria_emoji,
  c.color as categoria_color,
  -- Total en inventario
  coalesce(sum(d.cantidad), 0) as total_en_inventario,
  -- Solicitudes activas de este producto
  (select count(*) from public.solicitudes s 
   where s.producto_id = p.id and s.estado in ('activa'::estado_solicitud, 'parcialmente_cubierta'::estado_solicitud)
  ) as solicitudes_activas,
  p.updated_at as ultima_actualizacion
from public.productos p
join public.categorias c on c.id = p.categoria_id
left join public.donaciones d on d.producto_id = p.id
where p.es_excedente = true and p.activo = true and c.activa = true
group by p.id, p.nombre, p.cantidad_excedente, c.id, c.nombre, c.emoji, c.color, p.updated_at;

comment on view public.vista_excedentes_publicos is 'Vista pública de productos excedentes disponibles para otros centros';

-- 🆕 Vista: solicitudes activas con detalles
-- ============================================================
create or replace view public.vista_solicitudes_activas as
select 
  s.id,
  s.producto_nombre,
  s.cantidad_necesaria,
  s.cantidad_recibida,
  s.unidad,
  s.prioridad,
  s.descripcion,
  s.centro_solicitante,
  s.ubicacion,
  s.contacto_nombre,
  s.contacto_telefono,
  s.contacto_email,
  s.estado,
  s.fecha_solicitud,
  s.fecha_limite,
  c.nombre as categoria_nombre,
  c.emoji as categoria_emoji,
  c.color as categoria_color,
  case 
    when s.cantidad_necesaria > 0 then 
      round((s.cantidad_recibida::float / s.cantidad_necesaria) * 100, 1)
    else 0 
  end as porcentaje_cubierto,
  greatest(s.cantidad_necesaria - s.cantidad_recibida, 0) as cantidad_restante
from public.solicitudes s
join public.categorias c on c.id = s.categoria_id
where s.estado in ('activa'::estado_solicitud, 'parcialmente_cubierta'::estado_solicitud)
order by 
  case s.prioridad
    when 'urgente'::prioridad_solicitud then 1
    when 'alta'::prioridad_solicitud then 2
    when 'media'::prioridad_solicitud then 3
    when 'baja'::prioridad_solicitud then 4
  end,
  s.fecha_solicitud desc;

-- 🆕 Vista: coincidencias entre excedentes y solicitudes
-- ============================================================
create or replace view public.vista_coincidencias_excedentes_solicitudes as
select 
  e.producto_id,
  e.producto_nombre,
  e.categoria_nombre,
  e.categoria_emoji,
  e.cantidad_excedente,
  e.total_en_inventario,
  s.id as solicitud_id,
  s.centro_solicitante,
  s.cantidad_necesaria,
  s.cantidad_recibida,
  greatest(s.cantidad_necesaria - s.cantidad_recibida, 0) as cantidad_faltante,
  s.prioridad,
  s.ubicacion,
  s.contacto_telefono,
  s.contacto_email
from public.vista_excedentes_publicos e
join public.solicitudes s on s.categoria_id = e.categoria_id 
  and (s.producto_id = e.producto_id or s.producto_nombre = e.producto_nombre)
where s.estado in ('activa'::estado_solicitud, 'parcialmente_cubierta'::estado_solicitud);

comment on view public.vista_coincidencias_excedentes_solicitudes is 'Muestra coincidencias entre productos excedentes y solicitudes activas';

-- ============================================================
-- 7. DATOS SEMILLA
-- ============================================================

-- Categorías fijas
-- ============================================================
insert into public.categorias (id, nombre, emoji, color, es_fija) values
  ('a1111111-1111-1111-1111-111111111111', 'Higiene',   '🧴', 'blue',   true),
  ('a2222222-2222-2222-2222-222222222222', 'Alimentos', '🍚', 'green',  true),
  ('a3333333-3333-3333-3333-333333333333', 'Farmacia',  '💊', 'red',    true),
  ('a4444444-4444-4444-4444-444444444444', 'Ropa',      '👕', 'purple', true)
on conflict (id) do nothing;

-- Productos fijos de Higiene
-- ============================================================
insert into public.productos (categoria_id, nombre, es_fijo) values
  ('a1111111-1111-1111-1111-111111111111', 'Shampoo',                      true),
  ('a1111111-1111-1111-1111-111111111111', 'Perfumes',                     true),
  ('a1111111-1111-1111-1111-111111111111', 'Cepillos de dientes',          true),
  ('a1111111-1111-1111-1111-111111111111', 'Crema dental',                 true),
  ('a1111111-1111-1111-1111-111111111111', 'Toallas sanitarias',           true),
  ('a1111111-1111-1111-1111-111111111111', 'Toallitas húmedas',            true),
  ('a1111111-1111-1111-1111-111111111111', 'Jabón en barra',               true),
  ('a1111111-1111-1111-1111-111111111111', 'Toallas sanitarias post parto',true),
  ('a1111111-1111-1111-1111-111111111111', 'Papel toilet',                 true)
on conflict (categoria_id, nombre) do nothing;

-- Productos fijos de Alimentos
-- ============================================================
insert into public.productos (categoria_id, nombre, es_fijo) values
  ('a2222222-2222-2222-2222-222222222222', 'Compotas',       true),
  ('a2222222-2222-2222-2222-222222222222', 'Pasta',          true),
  ('a2222222-2222-2222-2222-222222222222', 'Arroz',          true),
  ('a2222222-2222-2222-2222-222222222222', 'Atún en lata',   true),
  ('a2222222-2222-2222-2222-222222222222', 'Harina de trigo',true),
  ('a2222222-2222-2222-2222-222222222222', 'Leche en polvo', true),
  ('a2222222-2222-2222-2222-222222222222', 'Fórmula láctea', true),
  ('a2222222-2222-2222-2222-222222222222', 'Enlatados',      true),
  ('a2222222-2222-2222-2222-222222222222', 'Agua',           true)
on conflict (categoria_id, nombre) do nothing;

-- Productos fijos de Farmacia
-- ============================================================
insert into public.productos (categoria_id, nombre, es_fijo) values
  ('a3333333-3333-3333-3333-333333333333', 'Alcohol',              true),
  ('a3333333-3333-3333-3333-333333333333', 'Pastillas',            true),
  ('a3333333-3333-3333-3333-333333333333', 'Solución yodada',      true),
  ('a3333333-3333-3333-3333-333333333333', 'Batas de pacientes',   true),
  ('a3333333-3333-3333-3333-333333333333', 'Mascarillas',          true),
  ('a3333333-3333-3333-3333-333333333333', 'Guantes',              true),
  ('a3333333-3333-3333-3333-333333333333', 'Gorros',               true),
  ('a3333333-3333-3333-3333-333333333333', 'Jeringas',             true),
  ('a3333333-3333-3333-3333-333333333333', 'Yelcos',               true)
on conflict (categoria_id, nombre) do nothing;

-- Producto genérico para Ropa
-- ============================================================
insert into public.productos (categoria_id, nombre, es_fijo) values
  ('a4444444-4444-4444-4444-444444444444', 'Prenda de ropa', true)
on conflict (categoria_id, nombre) do nothing;

-- ============================================================
-- 8. STORAGE BUCKET PARA IMÁGENES
-- ============================================================
insert into storage.buckets (id, name, public)
values ('donaciones-imagenes', 'donaciones-imagenes', true)
on conflict (id) do nothing;

-- Políticas de storage
-- ============================================================
drop policy if exists "donaciones_imagenes_upload" on storage.objects;
drop policy if exists "donaciones_imagenes_select" on storage.objects;
drop policy if exists "donaciones_imagenes_delete" on storage.objects;

create policy "donaciones_imagenes_upload" on storage.objects
  for insert with check (
    bucket_id = 'donaciones-imagenes' and 
    auth.role() = 'authenticated'
  );

create policy "donaciones_imagenes_select" on storage.objects
  for select using (bucket_id = 'donaciones-imagenes');

create policy "donaciones_imagenes_delete" on storage.objects
  for delete using (
    bucket_id = 'donaciones-imagenes' and 
    public.es_admin()
  );

-- ============================================================
-- 9. PERMISOS PARA ANON (acceso público a vistas)
-- ============================================================
grant select on public.vista_excedentes_publicos to anon, authenticated;
grant select on public.vista_solicitudes_activas to anon, authenticated;
grant select on public.vista_coincidencias_excedentes_solicitudes to anon, authenticated;
grant select on public.categorias to anon, authenticated;
grant select on public.productos to anon, authenticated;
grant select on public.solicitudes to anon, authenticated;

-- ============================================================
-- FIN DEL SCRIPT
-- ============================================================