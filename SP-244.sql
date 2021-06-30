SET TERM ^ ;

create or alter procedure E_CALCULATE_SBASE (
    EMPLREF EMPLOYEES_ID,
    FROMBASEPERIOD PERIOD_ID,
    TOBASEPERIOD PERIOD_ID,
    CURRENTCOMPANY COMPANIES_ID)
as
declare variable EMPLOYEE integer;
declare variable SBASE numeric(14,2);
declare variable SBASEGROSS numeric(14,2);
declare variable SWORKEDDAYS integer;
declare variable WORKDAYS integer;
declare variable FROMDATE date;
declare variable TODATE date;
declare variable EMPLSTART date;
declare variable TMP integer;
declare variable TAKEIT smallint;
declare variable HOURWAGE numeric(14,2);
declare variable WSK numeric(14,6);
declare variable WSK_OLD numeric(14,6);
declare variable IPER varchar(6);
declare variable ISBASE numeric(14,2);
declare variable PERIOD varchar(6);
declare variable TMPSBASE numeric(14,2);
declare variable BASESDIFF numeric(14,2);
declare variable EMPLTYPE smallint;
declare variable STDCALENDAR integer;
declare variable H_NORM_PER_DAY numeric(14,2); --SP-244
begin

  for
    select distinct p.employee, r.cper, r.empltype
      from epayrolls r
        join eprpos p on (p.payroll = r.ref)
        left join emplcontracts c on (r.emplcontract = c.ref)
       where r.cper <= :tobaseperiod
         and r.cper >= :frombaseperiod
         and r.company = :currentcompany
         and (p.employee = :emplref or :emplref is null)
         and (r.empltype = 1 or c.iflags like '%FC;%')
         and coalesce(r.tosbase,1) = 1 --PR30950
      order by p.employee, r.cper
      into :employee, :period, :empltype
  do begin

    execute procedure efunc_datesfromperiod(period)
      returning_values fromdate, todate; 

    if (empltype = 1) then
      select wd from ecal_work(:employee, :fromdate, :todate)
        into workdays;
    else begin
      if (stdcalendar is null) then
      begin
        execute procedure get_config('STDCALENDAR', 2)
          returning_values stdcalendar;
        if (not exists(select first 1 1 from ecalendars where ref = :stdcalendar)) then
          exception brak_kalendarza;
      end
      execute procedure ecaldays_store('COUNT', :stdcalendar, :fromdate, :todate) --PR53533
        returning_values :workdays;
    end

    select fromdate from employees
      where ref = :employee
      into :emplstart;

    takeit = 0;
    if (emplstart is null or emplstart <= fromdate) then
    begin
      tmp = null;
      select sum(a.workdays) from eabsences a
          join ecolparams c on (a.ecolumn = c.ecolumn)
        where a.employee = :employee and a.correction in (0,2)
          and a.fromdate >= :fromdate and a.todate <= :todate
          and c.param = 'ABSTYPE' and c.pval in (1,2)
        into :tmp;

      sworkeddays = workdays - coalesce(tmp, 0);
      if (sworkeddays >= workdays/2.00) then
        takeit = 1;
    end

    sbase = 0;
    sbasegross = 0;
    wsk_old = 0;
    tmpsbase = 0;
    for
      select distinct(r.iper)
        from epayrolls r
          join eprpos p on (p.payroll = r.ref)
          left join emplcontracts c on (r.emplcontract = c.ref)
        where r.cper = :period and p.employee = :employee
          and (r.empltype = 1 or c.iflags like '%FC;%')
          and coalesce(r.tosbase,1) = 1 --PR30950
        into :iper
    do begin
      isbase = null;
      select sum(p.pvalue)
        from epayrolls r
          join eprpos p on (p.payroll = r.ref)
          join ecolumns c on (c.number = p.ecolumn)
          left join emplcontracts co on (r.emplcontract = co.ref)
        where r.cper = :period and r.iper = :iper and c.cflags containing ';CHR;' and p.employee = :employee
          and (r.empltype = 1 or co.iflags like '%FC;%')
          and coalesce(r.tosbase,1) = 1 --PR30950
      into :isbase;
      isbase = coalesce(isbase, 0);

      hourwage = null;
      select max(p.pvalue)
        from epayrolls r
          join eprpos p on (p.payroll = r.ref)
          left join emplcontracts c on (r.emplcontract = c.ref)
        where r.cper = :period and r.iper = :iper and p.employee = :employee
          and p.ecolumn = 910
          and (r.empltype = 1 or c.iflags like '%FC;%')
          and coalesce(r.tosbase,1) = 1 --PR30950
        into :hourwage;

      if (hourwage is not null) then
      begin
        tmp = null;
        select sum(a.workdays)
          from eabsences a
            join epayrolls r on (a.epayroll = r.ref)
            join ecolparams c on (a.ecolumn = c.ecolumn)
          where r.cper = :period and r.iper = :iper and a.employee = :employee
            and a.fromdate >= :fromdate and a.todate <= :todate
            and c.param = 'ABSTYPE' and c.pval = 0
            and a.correction in (0,2)
            and coalesce(r.tosbase,1) = 1 --PR30950
          into :tmp;
        tmp = coalesce(tmp, 0);

--<XXX TD_20210526 SP-244 Uwzględnienie dobowej normy czasu pracy w godzinach dla wszystkich kalendarzy, również ze skróconym czasem pracy dla pracowników z wynagrodzeniem godzinowym
        select first 1 ec.norm_per_day / 3600.00
          from ecalendars ec
            join emplcalendar emc on ec.ref = emc.calendar
          where emc.employee = :employee
            and (emc.fromdate <= :fromdate and (emc.todate >= :todate or emc.todate is null))
          order by emc.fromdate desc
          into :h_norm_per_day;

        --isbase = isbase + ((workdays - tmp) * 8 * hourwage);
        isbase = isbase + ((workdays - tmp) * h_norm_per_day * hourwage);
--XXX>
      end

      basesdiff = 0;
      select sum(case when p.ecolumn = 6000 then p.pvalue else -p.pvalue end)
        from epayrolls r
          join eprpos p on (p.payroll = r.ref)
          join ecolumns c on (c.number = p.ecolumn)
          left join emplcontracts co on r.emplcontract = co.ref
        where r.cper = :period and r.iper = :iper and p.employee = :employee
          and p.ecolumn in (6000,6050)
          and (r.empltype = 1 or co.iflags like '%FC;%')
        into :basesdiff;

      --roznica miedzy podstawa chorobowa a emeryt.-rentowa? => przekroczenie limitu skladek
      if (coalesce(basesdiff,0) = 0) then
      begin
        execute procedure e_calculate_zus(period,currentcompany,0) --BS126355
          returning_values wsk;
      end else
      begin
        select sum(case when p.ecolumn in (6100,6110,6120,6130) then p.pvalue * 100.00 else 0 end) /    --skladki
               sum(case when p.ecolumn not in (6100,6110,6120,6130) then p.pvalue * 100.00 else 0 end)  --skladniki ZUS
          from epayrolls r
            join eprpos p on (p.payroll = r.ref)
            join ecolumns c on (c.number = p.ecolumn)
            left join emplcontracts co on (r.emplcontract = co.ref)
          where r.cper = :period and r.iper = :iper and p.employee = :employee
            and (c.number in (5990,6100,6110,6120,6130) or c.cflags containing ';ZUS;') --BS126355
            and (r.empltype = 1 or co.iflags like '%FC;%')
           into :wsk;

        wsk = wsk * 100;
      end

      wsk = 1 - (wsk) * 0.01;
      if (wsk_old = 0) then
        wsk_old = wsk;

      sbasegross = sbasegross + isbase;

      if (wsk <> wsk_old) then
      begin
        sbase = sbase + tmpsbase * wsk_old;
        tmpsbase = isbase;
        wsk_old = wsk;
      end else
        tmpsbase = tmpsbase + isbase;
    end
    sbase = sbase + tmpsbase * wsk;

    if (exists(select first 1 1 from eabsemplbases
                  where employee = :employee and period = :period)
    ) then begin
      update eabsemplbases set sbase = :sbase, workdays = :workdays,
          sworkeddays = :sworkeddays, sbasegross = :sbasegross, takeit = :takeit 
        where period = :period and employee = :employee;
    end else begin
      insert into eabsemplbases (employee, period, sbase, workdays, sworkeddays, takeit, sbasegross)
        values (:employee, :period, :sbase, :workdays, :sworkeddays, :takeit, :sbasegross);
    end
  end
end^

SET TERM ; ^

COMMENT ON PROCEDURE E_CALCULATE_SBASE IS
'BS23631;BS23032;BS22340;BS20914;BS07166;PR06091;PR15755;BS13067;BS19985;BS24653;BS25264;PR26529;BS27896;BS31603;BS33754;PR27177;BS34852;PR30950;PR48961;PR53741;PR69559;BS126355;SP-244;';

GRANT SELECT ON EPAYROLLS TO PROCEDURE E_CALCULATE_SBASE;

GRANT SELECT ON EPRPOS TO PROCEDURE E_CALCULATE_SBASE;

GRANT SELECT ON EMPLCONTRACTS TO PROCEDURE E_CALCULATE_SBASE;

GRANT EXECUTE ON PROCEDURE EFUNC_DATESFROMPERIOD TO PROCEDURE E_CALCULATE_SBASE;

GRANT EXECUTE ON PROCEDURE ECAL_WORK TO PROCEDURE E_CALCULATE_SBASE;

GRANT EXECUTE ON PROCEDURE GET_CONFIG TO PROCEDURE E_CALCULATE_SBASE;

GRANT SELECT ON ECALENDARS TO PROCEDURE E_CALCULATE_SBASE;

GRANT EXECUTE ON PROCEDURE ECALDAYS_STORE TO PROCEDURE E_CALCULATE_SBASE;

GRANT SELECT ON EMPLOYEES TO PROCEDURE E_CALCULATE_SBASE;

GRANT SELECT ON EABSENCES TO PROCEDURE E_CALCULATE_SBASE;

GRANT SELECT ON ECOLPARAMS TO PROCEDURE E_CALCULATE_SBASE;

GRANT SELECT ON ECOLUMNS TO PROCEDURE E_CALCULATE_SBASE;

GRANT SELECT ON EMPLCALENDAR TO PROCEDURE E_CALCULATE_SBASE;

GRANT EXECUTE ON PROCEDURE E_CALCULATE_ZUS TO PROCEDURE E_CALCULATE_SBASE;

GRANT SELECT,INSERT,UPDATE ON EABSEMPLBASES TO PROCEDURE E_CALCULATE_SBASE;

GRANT EXECUTE ON PROCEDURE E_CALCULATE_SBASE TO "ADMIN";
GRANT EXECUTE ON PROCEDURE E_CALCULATE_SBASE TO APATYNOWSKI;
GRANT EXECUTE ON PROCEDURE E_CALCULATE_SBASE TO LGABRYEL;
GRANT EXECUTE ON PROCEDURE E_CALCULATE_SBASE TO MSMEREKA;
GRANT EXECUTE ON PROCEDURE E_CALCULATE_SBASE TO SENTE;
GRANT EXECUTE ON PROCEDURE E_CALCULATE_SBASE TO SENTELOGIN;
GRANT EXECUTE ON PROCEDURE E_CALCULATE_SBASE TO SYSDBA;