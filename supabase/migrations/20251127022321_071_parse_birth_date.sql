-- 1) Fonction SECURISEE : parse_birth_date
--    Aucun impact tant qu'elle n'est pas utilisée.

create or replace function public.parse_birth_date(s text)
returns date
language plpgsql
immutable
as $$
declare
  t text;
  d date;
begin
  if s is null or length(trim(s)) = 0 then
    return null;
  end if;

  t := trim(s);

  -- Formats YYYY-MM-DD ou YYYY/MM/DD
  if t ~ '^\d{4}[-/]\d{2}[-/]\d{2}$' then
    begin
      d := to_date(replace(t, '/', '-'), 'YYYY-MM-DD');
      return d;
    exception when others then
      return null;
    end;
  end if;

  -- Formats DD-MM-YYYY ou DD/MM/YYYY (les plus courants en France)
  if t ~ '^\d{2}[-/]\d{2}[-/]\d{4}$' then
    begin
      d := to_date(replace(t, '/', '-'), 'DD-MM-YYYY');
      return d;
    exception when others then
      return null;
    end;
  end if;

  -- Formats séparés par des espaces : "12 07 1985" etc.
  if t ~ '^\d{1,2} \d{1,2} \d{4}$' then
    begin
      d := to_date(t, 'DD MM YYYY');
      return d;
    exception when others then
      return null;
    end;
  end if;

  -- Dernière tentative : try-catch général
  begin
    d := t::date;
    return d;
  exception when others then
    return null;
  end;

end;
$$;