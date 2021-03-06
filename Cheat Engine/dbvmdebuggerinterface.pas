unit DBVMDebuggerInterface;

//limited debugger, but still useful

{$mode delphi}

interface

uses
  jwawindows, windows, Classes, SysUtils,cefuncproc, newkernelhandler,
  DebuggerInterface,contnrs, vmxfunctions;

type
  TDBVMResumerThread=class(TThread)
  public
    procedure Execute; override; //frequently gets the frozen thread list and checks if it contains the CE process. If so, resume, and check more frequently
  end;


  TDBVMDebugInterface=class(TDebuggerInterface)
  private
    lastfrozenID: integer;
    currentFrozenID: integer;
    currentFrozenState: TPageEventExtended;


    lastContinueWasAStep: boolean; //if the last continue was a step then wait for lastfrozenID specifically until it gets abandoned (or takes 5 seconds)

    resumerThread: TDBVMResumerThread;

    processCR3: qword;
    procedure SteppingThreadLost;

    function setBreakEvent(var lpDebugEvent: TDebugEvent; frozenThreadID: integer): boolean;
  public
    usermodeloopint3: qword;
    kernelmodeloopint3: qword; static;
    OnSteppingthreadLoss: TNotifyEvent;
    constructor create;
    destructor destroy; override;
    function WaitForDebugEvent(var lpDebugEvent: TDebugEvent; dwMilliseconds: DWORD): BOOL; override;
    function ContinueDebugEvent(dwProcessId: DWORD; dwThreadId: DWORD; dwContinueStatus: DWORD): BOOL; override;
    function SetThreadContext(hThread: THandle; const lpContext: TContext; isFrozenThread: Boolean=false): BOOL; override;
    function GetThreadContext(hThread: THandle; var lpContext: TContext; isFrozenThread: Boolean=false):  BOOL; override;

    function DebugActiveProcess(dwProcessId: DWORD): BOOL; override;
    function needsToAttach: boolean; override;
    function controlsTheThreadList: boolean; override;
    function usesDebugRegisters: boolean; override;


  end;

var dbvm_bp_unfreezeselfcounter: integer;

implementation

uses DBK32functions, ProcessHandlerUnit, symbolhandler, simpleaobscanner,
  commonTypeDefs, symbolhandlerstructs, globals;



procedure TDBVMResumerThread.Execute;
var
  shortstate: TDBVMBPShortState;
  listsize: integer;
  sleeptime: integer;
  i: integer;

  inuse: byte;
  continueMethod: byte;
  cid: TClientID;
  thisprocess: dword;
  hadToUnfreeze: boolean;
begin
  thisprocess:=GetCurrentProcessId;

  sleeptime:=1000; //start with 1 second
  while not terminated do
  begin
    hadToUnfreeze:=false;
    listsize:=dbvm_bp_getBrokenThreadListSize;

    for i:=0 to listsize-1 do
    begin
      if dbvm_bp_getBrokenThreadEventShort(i,shortstate)=0 then
      begin
        inuse:=shortstate.status and $ff;
        continueMethod:=shortstate.status shl 8;
        if (inuse=1) and (continueMethod=0) then
        begin
          if getClientIDFromDBVMBPShortState(shortstate, cid) then //assuming this works for CE (else just do not read that memory while a watch bp is going on.  Perhaps a RPM/WPM hook)
          begin
            if cid.UniqueProcess=thisprocess then
            begin
              //a CE thread was frozen
              hadToUnfreeze:=true;
              dbvm_bp_resumeBrokenThread(i,2); //run, and be free little one
              inc(dbvm_bp_unfreezeselfcounter);
            end;
          end;
        end;
      end;
    end;

    if hadToUnfreeze then
      sleeptime:=sleeptime div 2
    else
      sleeptime:=min(1000, sleeptime*2+1);

    if sleeptime=0 then
    asm
     pause
    end;
    sleep(sleeptime);
  end;
end;


function TDBVMDebugInterface.setBreakEvent(var lpDebugEvent: TDebugEvent; frozenThreadID: integer):boolean;
var
  watchid, status: integer;
  clientid: TClientID;
begin
  result:=false;
  if dbvm_bp_getBrokenThreadEventFull(frozenThreadID, watchid, status, currentFrozenState)=0 then
  begin
    result:=true;
    currentFrozenID:=frozenThreadID;
    lpDebugEvent.dwDebugEventCode:=EXCEPTION_DEBUG_EVENT;
    lpDebugEvent.Exception.dwFirstChance:=1;
    lpDebugEvent.Exception.ExceptionRecord.ExceptionAddress:=pointer(currentFrozenState.basic.RIP);
    lpDebugEvent.Exception.ExceptionRecord.ExceptionCode:=EXCEPTION_DBVM_BREAKPOINT;
    lpDebugEvent.Exception.ExceptionRecord.ExceptionFlags:=watchid; //-1 when stepping
    lpDebugEvent.Exception.ExceptionRecord.NumberParameters:=6;
    lpDebugEvent.Exception.ExceptionRecord.ExceptionInformation[0]:=frozenThreadID;
    lpDebugEvent.Exception.ExceptionRecord.ExceptionInformation[1]:=currentFrozenState.basic.CR3;
    lpDebugEvent.Exception.ExceptionRecord.ExceptionInformation[2]:=currentFrozenState.basic.FSBASE;
    lpDebugEvent.Exception.ExceptionRecord.ExceptionInformation[3]:=currentFrozenState.basic.GSBASE;
    lpDebugEvent.Exception.ExceptionRecord.ExceptionInformation[4]:=currentFrozenState.basic.GSBASE_KERNEL;
    lpDebugEvent.Exception.ExceptionRecord.ExceptionInformation[5]:=ifthen<ULONG_PTR>(processCR3<>currentFrozenState.basic.CR3,1,0);

    if getClientIDFromDBVMBPState(currentFrozenState, clientID) then
    begin
      lpDebugEvent.dwProcessId:=clientID.UniqueProcess;
      lpDebugEvent.dwThreadId:=clientID.UniqueThread;

      if lpDebugEvent.dwProcessId=GetCurrentProcessId then exit(false); //resumer thread will do this one
    end
    else
    begin
      //failure getting it. Use the CR3 and GSBASE (or FSBASE if gs is 0)
      lpDebugEvent.dwProcessId:=currentFrozenState.basic.CR3 or (1 shl 31); //set the MSB to signal it's a 'special' id (it's not  big enough)
      lpDebugEvent.dwThreadId:=currentFrozenState.basic.GSBASE;
      if lpDebugEvent.dwThreadId=0 then
        lpDebugEvent.dwThreadId:=currentFrozenState.basic.FSBASE;

      if lpDebugEvent.dwThreadId=0 then
        lpDebugEvent.dwThreadId:=currentFrozenState.basic.GSBASE_KERNEL;

      lpDebugEvent.dwThreadId:=lpDebugEvent.dwThreadId or (1 shl 31);
    end;


  end;
end;

procedure TDBVMDebugInterface.SteppingThreadLost;
begin
  if assigned(OnSteppingthreadLoss) then
    OnSteppingthreadLoss(self);
end;

function TDBVMDebugInterface.WaitForDebugEvent(var lpDebugEvent: TDebugEvent; dwMilliseconds: DWORD): BOOL;
var
  starttime: qword;
  listsize: integer;
  i: integer;
  shortstate: TDBVMBPShortState;

  inuse: byte;
  continueMethod: byte;
  cid: TClientID;
begin
  starttime:=GetTickCount64;

  result:=false;

  repeat
    listsize:=dbvm_bp_getBrokenThreadListSize; //being not 0 does not mean there is an active bp, check if one is active (never goes down)

    if lastContinueWasAStep then
    begin
      lastContinueWasAStep:=false;

      //wait 5 seconds for this one
      while gettickcount64<starttime+5000 do
      begin
        if dbvm_bp_getBrokenThreadEventShort(lastfrozenID, shortstate)=0 then
        begin
          if (shortstate.status and $ff)=2 then //abandoned, stop waiting
          begin
            tthread.Queue(TThread.CurrentThread, SteppingThreadLost);
            break;
          end;

          if (shortstate.status shr 8)=0 then
          begin
            //it has finished the step properly
            exit(setBreakEvent(lpDebugEvent, lastfrozenID));
          end;

          //still here so step hasn't finished yet
          asm
          pause
          end;
          sleep(0);
        end
        else
          break;
      end;
    end;



    for i:=0 to listsize-1 do
    begin
      if dbvm_bp_getBrokenThreadEventShort(i,shortstate)=0 then
      begin
        inuse:=shortstate.status and $ff;
        continueMethod:=shortstate.status shl 8;

        if inuse=1 then
        begin
          if continueMethod=0 then //found a broken and waiting one
          begin
            cid.UniqueProcess:=0;
            if getClientIDFromDBVMBPShortState(shortstate,cid) then
            begin
              if cid.UniqueProcess=GetCurrentProcessId then continue; //let the resumer thread deal with this
            end;

            if dbvmbp_options.TargetedProcessOnly then
            begin
              //check if it's the correct process, if not, continue the bp
              if cid.UniqueProcess<>0 then
              begin
                if cid.UniqueProcess<>processid then //wrong pid
                begin
                  dbvm_bp_resumeBrokenThread(i,2);
                  continue;
                end;
              end
              else
              begin
                //getting the processid failed, try the CR3
                if processCR3<>shortstate.cr3 then //wrong cr3
                begin
                  dbvm_bp_resumeBrokenThread(i,2);
                  continue; //wrong cr3
                end;
              end;
            end;

            //still here, handling it
            exit(setBreakEvent(lpDebugEvent, i));
          end;
        end
        else
        begin
          //abandoned
          dbvm_bp_resumeBrokenThread(i,2); //frees the spot for new bp's
        end;
      end;
    end;
    asm
    pause
    end;
    sleep(0); //windows 10 fixed the sleep(0) where it will cause an immeadiate release of the timeslice
  until (dwMilliseconds=0) or (dword(gettickcount64-starttime)>dwMilliseconds); //if dwMilliseconds = INFINITE ($ffffffff) then this is never true


end;

function TDBVMDebugInterface.ContinueDebugEvent(dwProcessId: DWORD; dwThreadId: DWORD; dwContinueStatus: DWORD): BOOL;
var step: boolean;
begin
  try
    lastfrozenID:=currentFrozenID;
    if dwContinueStatus=DBG_CONTINUE_SINGLESTEP then
    begin
      OutputDebugString('TDBVMDebugInterface.ContinueDebugEvent returning single step');
      //single step
      lastContinueWasAStep:=true;
      dbvm_bp_resumeBrokenThread(currentFrozenID, 1); //step
    end
    else
    begin
      //run
      OutputDebugString('TDBVMDebugInterface.ContinueDebugEvent returning normal run');
      lastContinueWasAStep:=false;
      dbvm_bp_resumeBrokenThread(currentFrozenID, 2); //run
    end;

    result:=true;
  except
    result:=false;
  end;

end;

function TDBVMDebugInterface.needsToAttach: boolean;
begin
  result:=false;
end;

function TDBVMDebugInterface.controlsTheThreadList: boolean;
begin
  result:=false;
end;

function TDBVMDebugInterface.usesDebugRegisters: boolean;
begin
  result:=false; //doesn't give one fuck about debugregisters
end;

function TDBVMDebugInterface.SetThreadContext(hThread: THandle; const lpContext: TContext; isFrozenThread: Boolean=false): BOOL;
var f: dword;
begin

  if isFrozenThread then
  begin
    currentFrozenState.basic.FLAGS:=lpContext.EFlags;
    currentFrozenState.fpudata.MXCSR:=lpContext.MxCsr;

    currentFrozenState.basic.DR0:=lpContext.Dr0;
    currentFrozenState.basic.DR1:=lpContext.Dr1;
    currentFrozenState.basic.DR2:=lpContext.Dr2;
    currentFrozenState.basic.DR3:=lpContext.Dr3;
    currentFrozenState.basic.DR6:=lpContext.Dr6;
    currentFrozenState.basic.DR7:=lpContext.Dr7;


    currentFrozenState.basic.RAX:=lpContext.Rax;
    currentFrozenState.basic.RCX:=lpContext.Rcx;
    currentFrozenState.basic.Rdx:=lpContext.RDX;
    currentFrozenState.basic.Rbx:=lpContext.RBX;
    currentFrozenState.basic.Rsp:=lpContext.RSP;
    currentFrozenState.basic.Rbp:=lpContext.RBP;
    currentFrozenState.basic.Rsi:=lpContext.RSI;
    currentFrozenState.basic.Rdi:=lpContext.RDI;
    currentFrozenState.basic.R8:=lpContext.R8;
    currentFrozenState.basic.R9:=lpContext.R9;
    currentFrozenState.basic.R10:=lpContext.R10;
    currentFrozenState.basic.R11:=lpContext.R11;
    currentFrozenState.basic.R12:=lpContext.R12;
    currentFrozenState.basic.R13:=lpContext.R13;
    currentFrozenState.basic.R14:=lpContext.R14;
    currentFrozenState.basic.R15:=lpContext.R15;
    currentFrozenState.basic.Rip:=lpContext.Rip;
    CopyMemory(@currentFrozenState.fpudata, @lpContext.FltSave,512);

    result:=true;
  end
  else
    result:=false;
end;

function TDBVMDebugInterface.GetThreadContext(hThread: THandle; var lpContext: TContext; isFrozenThread: Boolean=false):  BOOL;
begin
  if isFrozenThread then
  begin

    lpContext.SegCs:=currentFrozenState.basic.CS;
    lpContext.SegDs:=currentFrozenState.basic.DS;
    lpContext.SegEs:=currentFrozenState.basic.ES;
    lpContext.SegFs:=currentFrozenState.basic.FS;
    lpContext.SegGs:=currentFrozenState.basic.GS;

    lpContext.EFlags:=currentFrozenState.basic.FLAGS;
    lpContext.MxCsr:=currentFrozenState.fpudata.MXCSR;

    lpContext.Dr0:=currentFrozenState.basic.DR0;
    lpContext.Dr1:=currentFrozenState.basic.DR1;
    lpContext.Dr2:=currentFrozenState.basic.DR2;
    lpContext.Dr3:=currentFrozenState.basic.DR3;
    lpContext.Dr6:=currentFrozenState.basic.DR6;
    lpContext.Dr7:=currentFrozenState.basic.DR7;


    lpContext.Rax:=currentFrozenState.basic.RAX;
    lpContext.Rcx:=currentFrozenState.basic.RCX;
    lpContext.Rdx:=currentFrozenState.basic.RDX;
    lpContext.Rbx:=currentFrozenState.basic.RBX;
    lpContext.Rsp:=currentFrozenState.basic.RSP;
    lpContext.Rbp:=currentFrozenState.basic.RBP;
    lpContext.Rsi:=currentFrozenState.basic.RSI;
    lpContext.Rdi:=currentFrozenState.basic.RDI;
    lpContext.R8:=currentFrozenState.basic.R8;
    lpContext.R9:=currentFrozenState.basic.R9;
    lpContext.R10:=currentFrozenState.basic.R10;
    lpContext.R11:=currentFrozenState.basic.R11;
    lpContext.R12:=currentFrozenState.basic.R12;
    lpContext.R13:=currentFrozenState.basic.R13;
    lpContext.R14:=currentFrozenState.basic.R14;
    lpContext.R15:=currentFrozenState.basic.R15;
    lpContext.Rip:=currentFrozenState.basic.Rip;

    lpContext.P1Home:=currentFrozenState.basic.Count;
    if processCR3<>currentFrozenState.basic.CR3 then
      lpContext.P2Home:=currentFrozenState.basic.CR3 //give the special cr3
    else
      lpContext.P2Home:=0; //normal access

    CopyMemory(@lpContext.FltSave, @currentFrozenState.fpudata,512);

    result:=true;
  end
  else
    result:=false;
end;


function TDBVMDebugInterface.DebugActiveProcess(dwProcessId: DWORD): BOOL;
var
  mi: TModuleInfo;
  buffer: array [0..4095] of byte;
  ka:ptruint;
  br: ptruint;
  i,j: integer;

  cr3log: array [0..512] of qword;
  mbi: TMEMORYBASICINFORMATION;
begin
  if (dwprocessid=0) or (dwProcessID=$ffffffff) then dwProcessId:=GetCurrentProcessId; //just a temporary id to get some usermode and kernelmode 'break'points

  if (processhandler.processid=0) or (processhandler.processid<>dwProcessId) then
  begin
    processhandler.processid:=dwProcessID;
    Open_Process;
    symhandler.kernelsymbols:=true;
    symhandler.reinitialize;
  end
  else
  begin
    if symhandler.kernelsymbols=false then
    begin
      symhandler.kernelsymbols:=true;
      symhandler.reinitialize;
    end;
  end;


  GetCR3(processhandle, processcr3);
  cr3log[0]:=processcr3;



  //scan executable memory for a CC
  try
    usermodeloopint3:=findaob('cc','+X',fsmNotAligned,'',true);
  except
    on e:exception do
    begin
      fErrorString:=e.message;
      exit(false);
    end;
  end;

  if dbvmbp_options.KernelmodeBreaks then
  begin
    if kernelmodeloopint3=0 then
    begin
      symhandler.waitforsymbolsloaded(true);
      if symhandler.getmodulebyname('ntoskrnl.exe',mi) then
      begin
        for i:=0 to 512 do
        begin
          if cr3log[i]=0 then break;  //end of the list

          ka:=mi.baseaddress;
          while (kernelmodeloopint3=0) and (ka<mi.baseaddress+mi.basesize) do
          begin
            if GetPageInfoCR3(cr3log[i],ka,mbi) then //get some page info (like if it's executable)
            begin
              if mbi.Protect in [PAGE_EXECUTE_READ,PAGE_EXECUTE_READWRITE] then
              begin
                while (kernelmodeloopint3=0) and (ka<ptruint(mbi.BaseAddress)+mbi.RegionSize) do
                begin
                  if ReadProcessMemoryCR3(cr3log[i],pointer(ka),@buffer,4096,br) then
                  begin
                    for j:=0 to 4095 do
                      if buffer[j]=$cc then
                      begin
                        kernelmodeloopint3:=ka+j;
                        break;
                      end;
                  end;
                  inc(ka,4096);
                end;
              end else ka:=ptruint(mbi.BaseAddress)+mbi.RegionSize;
            end else inc(ka,4096);
          end;

          if kernelmodeloopint3<>0 then break;

          if (i=0) then
          begin
            //need to fill the other cr3 values
            if dbvm_log_cr3values_start then
            begin
              ReadProcessMemory(processhandle,0,@br, 1,br);
              sleep(2000);
              if dbvm_log_cr3values_stop(@cr3log[1])=false then break; //give up
            end
            else break;

            //the other cr3 values are now filled in
          end;
        end;
      end;
    end;
  end
  else
    kernelmodeloopint3:=0;

  result:=true;
end;

constructor TDBVMDebugInterface.create;
begin
  inherited create;
  fDebuggerCapabilities:=fDebuggerCapabilities-[dbcCanUseInt1BasedBreakpoints];   //perhaps in the future add thread specific code

  resumerThread:=TDBVMResumerThread.Create(false);

end;

destructor TDBVMDebugInterface.destroy;
begin
  resumerThread.terminate;
  freeandnil(resumerThread);
  inherited destroy;
end;

end.

