function [cleanData,HBtimes,temp2e,period4,MCG,Rtopo]=correctHB(data,sRate,figOptions,ECG,cfg)

% - data is a matrix with rows for channels, raw data, not filtered. it can
% also be a filename.mat, directing to data matrix file, or a 4D filename such
% as 'c1,rfhp0.1Hz'.
% - sRate is sampling rate
% - figOptions=false;
% if you want fieldtrip topoplot of HB (first and second sweeps) you have to have:
% figOptions.label=N by 1 cell arraay with channel names of data
% figOptions.layout='4D248.lay' for 4D users. I recommend
% 'neuromag306mag.lay' for neuromag users even if data includes also grads.
% - ECG can be ECG (useful for ctf users) or a mean of subset of MEG channels where the HB is
% visible. neuromag users can put there the mean of the magnetometers to
% clean both magnetometers and gradiometers included in data.
%
% HB components   
%     /\      _____         /\      _____     
% __ /  \  __/     \______ /  \  __/     \__...
%   /    \/               /    \/ 
%   Q  R  S     T
%
%
%% cfg
% you can change variables by placing them in cfg. 
% lots of thresholds can be set and filters factors.
%
% a bit about the FILTERS.
% PEAK detection is performed on meanMEGf. a highpass is recommended to
% eliminate drift, but also the T wave which is sometimes larger than the R.
% cfg.peakFiltFreq sets the bandpass freqs for this one.
% the AMPLITUDE of R is estimated, but then you may want a highpass filter
% only, not to cut down R peak. cfg.ampFiltFreq can set up this filter as bp or hp.
% when using xcorr or Abeles method a TEMPLATE HB is fitted to the ECG like
% trace (meanMEG). another filter can be used there, in order to supress T
% for better timing. when the R is small and T can help the template match
% leave some low frequencies in. use tempFiltFreq for this one.


%  - cfg.chanSnrThr (default 0) is the threshold (in z scores) that tell which channels are cleaned and which
% remain as are. use 0 to clean all.
%  - cfg.rThr (0.5) is the threshold for correlation between topographies of averaged R peak
% and a particular R peak, it determains which instances of HB will be
% taken to calculate the HB temporal template
%  - cfg.minPeriod (0.45) low limit for HB period
%  - cfg.maxPeriod (2) upper limit for HB period
%  - cfg.chanZthr (20) z-score for declaring bad channels. A channel is bad
%  if it surpasses this value for 3 seconds in the beginning of the
%  - cfg.jPad (1) how much to zero pad before and after jump
%  - cfg.jZthr (15) is a z-score over which the meanMEG is considered to
%  have jump artifact
%  - cfg.peakFiltFreq ([7 90]) is the band-pass filter used for the meanMEG data, before peak
% detection.
%  - cfg.ampFiltFreq (2) is a high-pass or band-pass filter used to test R
% peak amplitude. better use highpass only, although bp may improve linear
% fit between (unfiltered) template and filtered data. 
%  - cfg.tempFiltFreq (same as peakFiltFreq) is the filter used for
%  meanMEG template and meanMEG before template match takes place. when
%  T is large and R is small you may want to lower the highpass freq. It
%  can save the day but beware, tricky business.
%  - cfg.matchMethod can be 'xcorr' (default) or 'Abeles', it is how you find
% the match between a template HB and meanMEG / ECG recording. you can also
% use 'topo' and 'meanMEG' in order to define HB peaks on the topography
% trace or the mean(MEG) channel. 

% 4D users can run the function from the folder with the data ('c,*') file, with no
% input arguments:
% cleanData=correctHB;
% or like this cleanData=correctHB([],[],1); to get the figures.
% if you don't specify figure options you still get one before / after figure.
% added by Dr. Yuval Harpaz to Prof. Abeles' work

% Issues
% - amplitude estimate per HB needs be better testing
% - only R amplitude is corrected, may consider to change q s and t waves.
% - memory problem, I should fix it to make topo and template based on the
% beginning of the data to clean the rest with it as well, piece by piece.
% - allow using a premade template, good for cleaning data in 2 pieces
% - 
% it works, try it!

%% default variables and parameters
if ~exist('figOptions','var')
    figOptions=[];
end
if isempty(figOptions)
    figs=false;
else
    figs=true;
end
if ~exist('ECG','var')
    ECG=[];
end
if ~exist('cfg','var')
    cfg=struct;
end
% uses default unless specified in the cfg
chanSnrThr=default('chanSnrThr',0,cfg);
rThr=default('rThr',0.5,cfg);
peakZthr=default('peakZthr',1.5,cfg);
minPeriod=default('minPeriod',0.45,cfg);
maxPeriod=default('maxPeriod',2,cfg);
chanZthr=default('chanZthr',20,cfg);
jPad=default('jPad',1,cfg);
jZthr=default('jZthr',15,cfg);
peakFiltFreq=default('peakFiltFreq',[7 90],cfg);
ampFiltFreq=default('ampFiltFreq',2,cfg);% [7 90] for band pass
tempFiltFreq=default('tempFiltFreq',peakFiltFreq,cfg);
matchMethod=default('matchMethod','xcorr',cfg);
linThr=0.25; % threshold for low amplitude HB, use average amplitude when below this ratio    

%% checking defaults for 4D data
% to use with data=[] and sRate=[];
if ~exist('data','var')
    data=[];
    sRate=[];
end
if ischar(data)
    if strcmp(data(end-3:end),'.mat') % read matrix from file 'data.mat'
        PWD=pwd;
        display(['loading ',PWD,'/',data,]);
        data=load(['./',data]);
        dataField=fieldnames(data);
        
        eval(['data=data.',dataField{1,1},';']);
    else % read 4D data from file name specified in 'data'
        cloc=strfind(data,'c');
        comaloc=strfind(data,',');
        if ~isempty(cloc) && ~isempty(comaloc)
            if comaloc(end)>cloc(1)
                var4DfileName=data;
            end
        end
    end
end

if isempty(data) || exist('var4DfileName','var');
    if ~exist('var4DfileName','var');
        try
            var4DfileName=ls('xc,lf_c,*');
        catch %#ok<CTCH>
            var4DfileName=ls('c,*');
        end
        var4DfileName=['./',var4DfileName(1:end-1)];
    end
    
    var4Dp=pdf4D(var4DfileName);
    sRate=double(get(var4Dp,'dr'));
    var4Dhdr = get(var4Dp, 'header');
    var4DnSamp=var4Dhdr.epoch_data{1,1}.pts_in_epoch;
    var4Dchi = channel_index(var4Dp, 'meg', 'name');
    display(['reading ',var4DfileName]);
    data = read_data_block(var4Dp,[1 var4DnSamp],var4Dchi);
    %data=double(data);
    if figs
        var4Dlabel=channel_label(var4Dp,var4Dchi)';
        if figOptions==1;
            clear figOptions
        end
        figOptions.label=var4Dlabel;
        figOptions.layout='4D248.lay';
    end
    clear var4D*
end

if ~isempty(ECG)
    meanMEG=ECG;
    %meanMEGdt=detrend(meanMEG,'linear',round(sRate:sRate:length(meanMEG)));
else
    meanMEG=double(mean(data));
end
%% pad with zeros for templite slide
sampBefore=round(sRate*maxPeriod);
%time=1/sRate:1/sRate:size(data,2)/sRate;
time=-sampBefore/sRate:1/sRate:(size(data,2)+sampBefore)/sRate;
time=time(2:end);
origDataSize=size(data);
meanMEG=[zeros(1,sampBefore),meanMEG,zeros(1,sampBefore)];
data=[zeros(size(data,1),sampBefore),data,zeros(size(data,1),sampBefore)];

realDataSamp=[sampBefore+1,size(data,2)-sampBefore];
%% filter mean MEG (or ECG) data
% filtering to pass from 5-7Hz to 90-110Hz
if ~(peakFiltFreq(1)>1)
    Fst1=0.0001;
else
    Fst1=peakFiltFreq(1)-1;
end
BandPassSpecObj=fdesign.bandpass(...
    'Fst1,Fp1,Fp2,Fst2,Ast1,Ap,Ast2',...
    Fst1,peakFiltFreq(1),peakFiltFreq(2),peakFiltFreq(2)+10,60,1,60,sRate);
BandPassFilt=design(BandPassSpecObj ,'butter');
meanMEGf = myFilt(meanMEG,BandPassFilt);
% baseline correction again, just in case
meanMEGf=meanMEGf-median(meanMEGf);

%% look for a noisy segment and noisy channels
% find bad channels, has to be noisy for 3 of the first 3 seconds
stdMEG=std(data(:,1:round(sRate))');
badc1=stdMEG>chanZthr*median(stdMEG);
stdMEG=std(data(:,round(sRate):round(2*sRate))');
badc2=stdMEG>chanZthr*median(stdMEG);
stdMEG=std(data(:,round(2*sRate):round(3*sRate))');
badc3=stdMEG>chanZthr*median(stdMEG);
badc=find((badc1+badc2+badc3)==3);
if ~isempty(badc)
    data(badc,:)=0;
end

% find jump or other huge artifact
zMEG=(meanMEGf-mean(meanMEGf))./std(meanMEGf);
jbeg=find(abs((zMEG))>jZthr,1);% 
j=find(abs((zMEG))>jZthr);
bads=[]; % bad samples
if ~isempty(jbeg)
    %jend=find(abs((zMEG))>zThr,1,'last');
    %jend2=find(abs(zMEG(jend:end))>1,1,'last')+jend-1;
    for jumpi=1:length(j)
        bads=[bads,j(jumpi)-round(sRate*jPad):j(jumpi)+sRate*jPad]; %#ok<AGROW>
    end
    %bads(bads<sampBefore+1)=sampBefore+1;
    bads=unique(bads);
    badData=data(:,bads);
    %bads=(jbeg-round(sRate./2)):(jend2+round(sRate*0.5));
    data(:,bads)=0;
    if length(data)<2^19
        data=data-repmat(median(data,2),1,size(data,2));
    else
        for chani=1:size(data,1)
            data(chani,:)=data(chani,:)-median(data(chani,:),2);
        end
    end
    diary('HBlog.txt')
    warning(['jump? what''','s the noise at ',num2str(time(jbeg)),'s? zeroed noise from ',num2str(time(bads(1))),' to ',num2str(time(bads(end)))]);
    diary off
    % end
else
    % baseline correction by removing the median of each channel
    if length(data)<2^19
        data=data-repmat(median(data,2),1,size(data,2));
    else
         for chani=1:size(data,1)
            data(chani,:)=data(chani,:)-median(data(chani,:),2);
         end
    end
end
if isempty(ECG)
    meanMEG=double(mean(data));
    meanMEGf = myFilt(meanMEG,BandPassFilt);
    meanMEGf=meanMEGf-median(meanMEGf);
end
%% peak detection on MCG (or ECG) signal
[peaks, Ipeaks]=findPeaks(meanMEGf,peakZthr,round(sRate*minPeriod)); % 450ms interval minimum
% test if, by chance, the HB field is mainly negative
posHB=true;
if isempty(ECG)
        [peaksNeg, IpeaksNeg]=findPeaks(-meanMEGf,peakZthr,round(sRate*minPeriod));
    if median(peaksNeg)/median(peaks)>1.1
        diary('HBlog.txt')
        warning('NEGATIVE HB FIELD? if not, average selected MEG channels and give it as ECG');
        diary off
        period1=median(diff(IpeaksNeg))./sRate;
        if period1<2
            [peaks, Ipeaks]=findPeaks(-meanMEGf,peakZthr,round(sRate*period1*0.6));
            peaks=-peaks;
        else
            Ipeaks=IpeaksNeg;
            peaks=-peaksNeg;
        end
        posHB=false;
        %meanMEGf=-meanMEGf;
    else
        period1=median(diff(Ipeaks))./sRate;
        if period1<2 %#ok<*BDSCI> %try to improve peak detection if peak intervals are reasonable
            [peaks, Ipeaks]=findPeaks(meanMEGf,peakZthr,round(sRate*period1*0.6)); % 450ms interval
        end
    end
end
if figs
    figure;
    plot(time,meanMEGf)
    hold on
    plot(time(Ipeaks), peaks,'ro')
    title('peak detection on mean MEG (or ECG) trace, OK if many of them are not HB')
end
%% get topography
if figs
    if isfield(figOptions,'layout') && isfield(figOptions,'label')
        topo={};
        topo.avg=median(data(:,Ipeaks),2);
        topo.time=0;
        topo.label=figOptions.label;
        topo.dimord='chan_time';
        cfgp=[];
        cfgp.layout=figOptions.layout;
        if ~isempty(badc)
            cfgp.channel=setdiff(1:length(topo.label),badc);
        end
        if strcmp(cfgp.layout,'neuromag306mag.lay')
            [~,magi]=ismember({'MEG0111';'MEG0121';'MEG0131';'MEG0141';'MEG0211';'MEG0221';'MEG0231';'MEG0241';'MEG0311';'MEG0321';'MEG0331';'MEG0341';'MEG0411';'MEG0421';'MEG0431';'MEG0441';'MEG0511';'MEG0521';'MEG0531';'MEG0541';'MEG0611';'MEG0621';'MEG0631';'MEG0641';'MEG0711';'MEG0721';'MEG0731';'MEG0741';'MEG0811';'MEG0821';'MEG0911';'MEG0921';'MEG0931';'MEG0941';'MEG1011';'MEG1021';'MEG1031';'MEG1041';'MEG1111';'MEG1121';'MEG1131';'MEG1141';'MEG1211';'MEG1221';'MEG1231';'MEG1241';'MEG1311';'MEG1321';'MEG1331';'MEG1341';'MEG1411';'MEG1421';'MEG1431';'MEG1441';'MEG1511';'MEG1521';'MEG1531';'MEG1541';'MEG1611';'MEG1621';'MEG1631';'MEG1641';'MEG1711';'MEG1721';'MEG1731';'MEG1741';'MEG1811';'MEG1821';'MEG1831';'MEG1841';'MEG1911';'MEG1921';'MEG1931';'MEG1941';'MEG2011';'MEG2021';'MEG2031';'MEG2041';'MEG2111';'MEG2121';'MEG2131';'MEG2141';'MEG2211';'MEG2221';'MEG2231';'MEG2241';'MEG2311';'MEG2321';'MEG2331';'MEG2341';'MEG2411';'MEG2421';'MEG2431';'MEG2441';'MEG2511';'MEG2521';'MEG2531';'MEG2541';'MEG2611';'MEG2621';'MEG2631';'MEG2641'},topo.label);
            %topo.avg=topo.avg(chi);
            %topo.label=topo.label(chi);
            cfgp.xlim=[1,1];
            cfgp.zlim=[-max(abs(topo.avg(magi))) max(abs(topo.avg(magi)))];
            figure;
            ft_topoplotER(cfgp,topo);
            title('MAGNETOMETERS, TOPOGRAPHY OF R')
            % cfg.layout='neuromag306planar.lay';
            % grd=topo.avg;
            % grd(chi)=0;
            % cfg.zlim=[-max(abs(grd)) max(abs(grd))];
            % figure;
            % ft_topoplotER(cfg,topo);
            % title('GRADIOMETERS')
        else
            %cfg.channel={'MEG0111';'MEG0121';'MEG0131';'MEG0141';'MEG0211';'MEG0221';'MEG0231';'MEG0241';'MEG0311';'MEG0321';'MEG0331';'MEG0341';'MEG0411';'MEG0421';'MEG0431';'MEG0441';'MEG0511';'MEG0521';'MEG0531';'MEG0541';'MEG0611';'MEG0621';'MEG0631';'MEG0641';'MEG0711';'MEG0721';'MEG0731';'MEG0741';'MEG0811';'MEG0821';'MEG0911';'MEG0921';'MEG0931';'MEG0941';'MEG1011';'MEG1021';'MEG1031';'MEG1041';'MEG1111';'MEG1121';'MEG1131';'MEG1141';'MEG1211';'MEG1221';'MEG1231';'MEG1241';'MEG1311';'MEG1321';'MEG1331';'MEG1341';'MEG1411';'MEG1421';'MEG1431';'MEG1441';'MEG1511';'MEG1521';'MEG1531';'MEG1541';'MEG1611';'MEG1621';'MEG1631';'MEG1641';'MEG1711';'MEG1721';'MEG1731';'MEG1741';'MEG1811';'MEG1821';'MEG1831';'MEG1841';'MEG1911';'MEG1921';'MEG1931';'MEG1941';'MEG2011';'MEG2021';'MEG2031';'MEG2041';'MEG2111';'MEG2121';'MEG2131';'MEG2141';'MEG2211';'MEG2221';'MEG2231';'MEG2241';'MEG2311';'MEG2321';'MEG2331';'MEG2341';'MEG2411';'MEG2421';'MEG2431';'MEG2441';'MEG2511';'MEG2521';'MEG2531';'MEG2541';'MEG2611';'MEG2621';'MEG2631';'MEG2641'};
            %cfg.interpolation='linear';
            cfgp.xlim=[1,1];
            cfgp.zlim=[-max(abs(topo.avg)) max(abs(topo.avg))];
            figure;
            ft_topoplotER(cfgp,topo);
            title('TOPOGRAPHY OF R')
        end
    else
        warning('no topoplot without labels and layout fields! see figOptions options')
    end
end
topoTrace=median(data(:,Ipeaks),2)'*data;
topoTrace=myFilt(topoTrace,BandPassFilt);
topoTrace=topoTrace-median(topoTrace);
% if ~posHB
%     meanMEGN=meanMEGf./max(-meanMEGf(1:round(sRate*10)));
%     topoTraceN=-topoTrace./max(topoTrace(1:round(sRate*10)));
% else
%     topoTraceN=topoTrace./max(topoTrace(1:round(sRate*10)));
%     meanMEGN=meanMEGf./max(meanMEGf(1:round(sRate*10)));
% end
meanMEGN=standard(meanMEGf);
topoTraceN=standard(topoTrace);
if ~posHB
    topoTraceN=-topoTraceN;
end


%% check if topo of every peak is correlated to average topo
r=corr(data(:,Ipeaks),median(data(:,Ipeaks),2));
if figs
    figure;
    plot(time,topoTraceN)
    hold on
    plot(time,meanMEGN,'r')
    plot(time(Ipeaks(r>0.5)),meanMEGN(Ipeaks(r>0.5)),'g.');
    legend('topoTrace','meanMEG','r data-topo > 0.5')
end
%% average good HB and make a template
IpeaksR=Ipeaks(r>0.5);
IpeaksR=IpeaksR(IpeaksR>sampBefore);
IpeaksR=IpeaksR(IpeaksR<(size(data,2)-sampBefore));
period2=diff(IpeaksR)/sRate; % estimate period
period2=median(period2(period2<2)); % less than 2s

%LowPassSpecObj=fdesign.lowpass('Fp,Fst,Ap,Ast',45,55,1,60,sRate);
if tempFiltFreq==peakFiltFreq
    meanMEGxcrF=meanMEGf;
else
    if length(tempFiltFreq)==2
        Fp1=tempFiltFreq(1);
        Fst1=max([0.001,Fp1-1]);
        ObjXcr=fdesign.bandpass(...
            'Fst1,Fp1,Fp2,Fst2,Ast1,Ap,Ast2',...
            Fst1,Fp1,tempFiltFreq(2),tempFiltFreq(2)+10,60,1,60,sRate);
    elseif length(tempFiltFreq)==1
        if tempFiltFreq<15
            ObjXcr=fdesign.highpass('Fst,Fp,Ast,Ap',max([ampFiltFreq-1,0.001]),ampFiltFreq,60,1,sRate);%
        elseif tempFiltFreq>=15
            ObjXcr=fdesign.lowpass('Fp,Fst,Ap,Ast',tempFiltFreq,tempFiltFreq+10,1,60,sRate);
        end
        FiltXcr=design(ObjXcr ,'butter');
        meanMEGxcrF = myFilt(meanMEG,FiltXcr);
    end
end
    
    
% meanMEGxcrF = myFilt(meanMEG,BandPassFiltXcr);
meanMEGxcrF=meanMEGxcrF-median(meanMEGxcrF);
if posHB
    [temp1e,period3]=makeTempHB(meanMEGxcrF,sRate,IpeaksR,period2,sampBefore,figs,maxPeriod);
else
    [temp1e,period3]=makeTempHB(-meanMEGxcrF,sRate,IpeaksR,period2,sampBefore,figs,maxPeriod);
end
%% find xcorr between template and meanMEG
maxi=round(0.3*length(temp1e))+1; %maxi is where the R peak in the template
[~,mi]=max(temp1e(maxi-round(sRate/100):maxi+round(sRate/100)));
maxi=maxi-round(sRate/100)+mi-1;
if posHB
    meanMEGpos=meanMEGxcrF;
else
    meanMEGpos=-meanMEGxcrF;
end
switch matchMethod
    case 'xcorr'
        matchTrace=XCORR(meanMEGpos,temp1e,maxi);
    case 'Abeles'
        [snr,signal]=matchTemp(meanMEGxcrF,temp1e,maxi);
        matchTrace=snr;
    case 'topo'
        matchTrace=topoTrace;
    case 'meanMEG'
        matchTrace=meanMEGf;
end


if figs
    figure;
    plot(time,topoTraceN)
    hold on
    plot(time,meanMEGN,'r')
    if posHB
        plot(time,standard(matchTrace),'g');
    else
        plot(time,-standard(matchTrace),'g');
    end
    legend('topoTrace','meanMEG','temp xcorr')
end
%% second sweep
%% find peaks on xcorr trace
[peaks2, Ipeaks2]=findPeaks(matchTrace,peakZthr,round(sRate*period3*0.65)); % no peaks closer than 60% of period
if figs
    figure;
    if posHB
        plot(time,matchTrace)
        hold on
        plot(time(Ipeaks2), peaks2,'ro')
    else
        plot(time,-matchTrace)
        hold on
        plot(time(Ipeaks2), -peaks2,'ro')
    end
    title('2nd sweep peak detection, based on template matching')
end
% checking results
periodS=diff(Ipeaks2);% the period in samples for each HB
farI=find(periodS/median(periodS)>1.5);
if median(periodS)/sRate<0.5
    diary('HBlog.txt')
    warning('interval between HB is less than 0.5s, look at the figures!')
    diary off
elseif median(periodS)/sRate>1.5
    diary('HBlog.txt')
    warning('interval between HB is more than 1.5s, look at the figures!')
    diary off
else
    if ~isempty(farI)
        farT=Ipeaks2(farI)/sRate; % this is far time, not what you think!
        diary('HBlog.txt')
        disp('sparse heartbeats, you may want to look for missing HB after:');
        disp(num2str(farT));
        diary off
    end
    nearI=find(periodS/median(periodS)<0.5);
    if ~isempty(nearI)
        nearT=Ipeaks2(nearI)/sRate;
        diary('HBlog.txt')
        disp('close heartbeats, you may want to look for false HB detection after:');
        disp(num2str(nearT));
        diary off
    end
end
% ignore edges
Ipeaks2in=Ipeaks2(Ipeaks2>sampBefore);
Ipeaks2in=Ipeaks2in(Ipeaks2in<(size(data,2)-sampBefore));
% make mcg trace for meanMEG
if posHB
    [temp2e,period4]=makeTempHB(meanMEG,sRate,Ipeaks2in,period3,sampBefore,figs,maxPeriod);
else
    [temp2e,period4]=makeTempHB(-meanMEG,sRate,Ipeaks2in,period3,sampBefore,figs,maxPeriod);
end

maxi=round(0.3*length(temp2e))+1;
[~,mi]=max(temp2e(maxi-round(sRate/100):maxi+round(sRate/100)));
maxi=maxi-round(sRate/100)+mi-1;
%% test R amplitude
% meanMEGdt=detrend(meanMEG,'linear',round(sRate:sRate:length(meanMEG)));
if length(ampFiltFreq)==1
    HighPassSpecObj=fdesign.highpass('Fst,Fp,Ast,Ap',ampFiltFreq-1,ampFiltFreq,60,1,sRate);%
HighPassFilt=design(HighPassSpecObj ,'butter');
meanMEGampF = myFilt(meanMEG,HighPassFilt);
% baseline correction again, just in case
meanMEGampF=meanMEGampF-median(meanMEGampF);
elseif length(ampFiltFreq)==2
    if isequal(ampFiltFreq,[7 90])
        meanMEGampF=meanMEGf;
    else
        BandPassSpecObjAmp=fdesign.bandpass(...
            'Fst1,Fp1,Fp2,Fst2,Ast1,Ap,Ast2',...
            ampFiltFreq(1)-1,ampFiltFreq(1),ampFiltFreq(2),ampFiltFreq(2)+10,60,1,60,sRate);
        BandPassFiltAmp=design(BandPassSpecObjAmp ,'butter');
        meanMEGampF = myFilt(meanMEG,BandPassFiltAmp);
        % baseline correction again, just in case
        meanMEGampF=meanMEGampF-median(meanMEGampF);
    end
else
    error('wrong length of vector. one number (2) means hp filter, two ([2 90]) means bp')
end

[p,Rlims]=assessAmp(temp2e,maxi,Ipeaks2in,meanMEGampF);
% look for neg correlation between template peak and peaks, means trouble
% if there are too many

if posHB
    negp=find(p(:,1)<linThr);
else
    negp=find(p(:,1)>linThr);
end
if ~isempty(negp)
    p(negp,1:2)=0;
    diary('HBlog.txt')
    warning(['did not get good fit for amplitude test, assume average HB amplitude at ',num2str(time(Ipeaks2in(negp)))])
    diary off
end
ampMMfit=p(:,1)+(p(:,2)./temp2e(maxi));
if posHB
    MCG=makeMCG(temp2e,maxi,Rlims,Ipeaks2in,ampMMfit,length(meanMEG));
else
    MCG=makeMCG(temp2e,maxi,Rlims,Ipeaks2in,-ampMMfit,length(meanMEG));
    MCG=-MCG;
end

%% remove mcg from each chan
%make temp per chan
sBef=maxi-1;
sAft=length(temp2e)-maxi;
HBtemp=HBbyChan(data,sRate,Ipeaks2in,sBef,sAft);
% check SNR per chan
sm50=round(sRate*0.05);
s0=maxi-sm50*3;
s1=maxi-sm50;
s2=maxi+sm50;
n=std(HBtemp(:,s0:s1)'); %#ok<*UDIM>
s=std(HBtemp(:,s1:s2)');
snr=s./n;
badSNR=find(snr<=chanSnrThr);
if figs
    timeTemp=1/sRate:1/sRate:size(HBtemp,2)/sRate;
    timeTemp=timeTemp-maxi/sRate;
    figure;plot(timeTemp,HBtemp','k');hold on;
    %plot(maxi,HBtemp(find(HBsnr>1.1),maxi),'g.')
    [~,minI]=min(snr);
    plot(timeTemp,HBtemp(minI,:),'r');
    if isempty(badSNR) || chanSnrThr==0
        title('HB for all channels,red trace is worst SNR channel')
    else
        plot(timeTemp(maxi),HBtemp(badSNR,maxi),'r.')
        title(['HB for all channels. red trace is worst SNR channel, dots mark channels with SNR < ',num2str(chanSnrThr)])
    end
end
if ~isempty(badSNR)
    if length(find(snr<=chanSnrThr))>size(data,1)/2
        error('too many channels have poor SNR. was there artifact?')
    end
    if ~chanSnrThr==0
        HBtemp(badSNR,:)=0;
        diary('HBlog.txt')
        disp(['not including bad SNR channels, index no. ',num2str(badSNR)])
        diary off
    end
end
if posHB
    MCGall=makeMCGbyCh(HBtemp,maxi,Rlims,Ipeaks2in,ampMMfit,length(meanMEG));
else
    MCGall=makeMCGbyCh(HBtemp,maxi,Rlims,Ipeaks2in,-ampMMfit,length(meanMEG));
end
cleanData=data-MCGall;
figure;
if isempty(ECG)
    plot(time,MCG,'k')
else
    scale=max(abs(MCG(sampBefore+1:sampBefore+round(sRate*5))))/max(abs(mean(cleanData(:,sampBefore+1:sampBefore+round(sRate*5)))));
    plot(time,meanMEG/scale,'k')
end
hold on
plot(time,mean(data),'r')
plot(time,mean(cleanData),'g')
if isempty(ECG)
legend('MCG from template', 'mean MEG','mean clean MEG')
else
    legend('rescaled ECG', 'mean MEG','mean clean MEG')
end
Rtopo=HBtemp(:,maxi);
if figs
    if isfield(figOptions,'layout')
        topo.avg=Rtopo;
        cfgp.xlim=[1,1];
        if strcmp(cfgp.layout,'neuromag306mag.lay')
            cfgp.zlim=[-max(abs(topo.avg(magi))) max(abs(topo.avg(magi)))];
            figure;
            ft_topoplotER(cfgp,topo);
            title('MAGNETOMETERS, TOPOGRAPHY OF R, 2nd sweep')
        else
            cfgp.zlim=[-max(abs(Rtopo)) max(abs(Rtopo))];
            figure;
            ft_topoplotER(cfgp,topo);
            title ('TOPOGRAPHY OF R, 2nd sweep')
        end
    end
end
display(['HB period (2nd sweep) is ',num2str(period4),'s']);
if ~isempty(bads);
    cleanData(:,bads)=badData;
end
cleanData=cleanData(:,sampBefore+1:end-sampBefore);
HBtimes=Ipeaks2in/sRate;
%% internal functions
function [tempe,period4]=makeTempHB(trace,sRate,peakIndex,period,sampBefore,figs,maxPeriod)
betweenHBs=0.7; % after the T wave, before next qrs, 0.7 of period
HB=zeros(size(trace,1),sampBefore*2+1);
for epochi=1:length(peakIndex)
    HB=HB+trace(:,peakIndex(epochi)-sampBefore:peakIndex(epochi)+sampBefore);
end
HB=HB/epochi;
period4=[]; %#ok<NASGU>
HBxc=xcorr(HB);
[~,ipxc]=findPeaks(HBxc,1.5,sRate*period*0.6); % index peak xcorr
if length(ipxc)>1
    nextPeak=ceil(length(ipxc)/2+0.5);
    period4=(ipxc(nextPeak)-ipxc(nextPeak-1))/sRate;
    % else
    xcorrByseg=false;
    if length(trace)>=2^20 % test if version is later than 1011b
        ver=version('-release');
        if ~strcmp(ver,'2011b')
            if str2num(ver(1:end-1))<=2011
                xcorrByseg=true;
            end
        end
    end
    if xcorrByseg
        trace1=trace;
        difs=[];
        while length(trace1)>length(HB)*3 %2^20
            if length(trace1)>2^20
                trace2=trace1(1:2^20);
                trace1=trace1(2^20+1:end);
            else
                trace2=trace1;
                trace1=0;
            end
            xcCurrent=xcorr(trace2,HB);
            xcCurrent=xcCurrent(find(xcCurrent,1):end);
            [~,ipxcCur]=findPeaks(xcCurrent,1.5,sRate*period*0.6);
            difs=[difs,diff(ipxcCur)]; %#ok<AGROW>
        end
        period4=median(difs(difs/sRate<maxPeriod))/sRate;
    else
        HBxc1=xcorr(trace,HB);
        [~,ipxc]=findPeaks(HBxc1,1.5,sRate*period*0.6); % index peak xcorr
        period4=median(diff(ipxc))/sRate;
    end
else
    warning('could not find cross correlation within extended template, guessing period')
    period4=period;
end
temp=HB(sampBefore-round(sRate*(1-betweenHBs)*period4):sampBefore+round(sRate*betweenHBs*period4));
edgeRepressor=ones(size(temp));
ms20=round(sRate/50);
reducVec=0:1/ms20:1;
reducVec=reducVec(1:end-1);
edgeRepressor(1:length(reducVec))=reducVec;
edgeRepressor(end-length(reducVec)+1:end)=fliplr(reducVec);
tempe=temp-median(temp);
tempe=tempe.*edgeRepressor;
time=1/sRate:1/sRate:length(temp)/sRate;
time=time-(1-betweenHBs)*period4;
if figs
    figure;
    plot(time,tempe,'g')
    title('template HB')
end
tempe=double(tempe);

function MCG=makeMCG(temp,maxTemp,Rlims,Ipeaks,amp,lengt)
MCG=zeros(1,lengt);
HBol=[]; %overlap
olCount=0;
%[~,maxTemp]=max(temp(1:round(length(temp/2))));
for HBi=1:length(Ipeaks);
    s0=Ipeaks(HBi)-maxTemp+1;
    s1=Ipeaks(HBi)+length(temp)-maxTemp;
    if sum(MCG(s0:s1))>0
        overlap=find(MCG(s0:s1),1,'last');
        if overlap>0.2*length(temp)
            endPrev=round(0.2*length(temp));
        else
            endPrev=overlap;
        end
%         sampDif=round(sRate/50);
        reducVec=1:-1/endPrev:1/endPrev;
        reducVecLR=fliplr(reducVec);
        reducVec(end+1:length(temp))=0;
        reducVecLR(end+1:length(temp))=1;
        MCG(s0:s1)=MCG(s0:s1).*reducVec+temp.*reducVecLR;
        olCount=olCount+1;
        HBol(olCount)=HBi;
    else
        MCG(s0:s1)=MCG(s0:s1)+temp;
    end
    MCG(s0+Rlims(1)-1:s0+Rlims(2)-1)=temp(Rlims(1):Rlims(2))*amp(HBi);
end
% if ~isempty(HBol)
% diary('HBlog.txt')
% disp(['overlapping heartbeats at ',num2str(Ipeaks(HBol/sRate)),'s'])
% diary off
% end
function tempe=HBbyChan(trace,sRate,peakIndex,sampBefore,sampAfter)
HB=zeros(size(trace,1),sampBefore+1+sampAfter);
% average HBs
for epochi=1:length(peakIndex)
    HB=HB+trace(:,peakIndex(epochi)-sampBefore:peakIndex(epochi)+sampAfter);
end
HB=HB/epochi;
% reduce edges to vero
edgeRepressor=ones(1,size(HB,2));
ms20=round(sRate/50);
reducVec=0:1/ms20:1;
reducVec=reducVec(1:end-1);
edgeRepressor(1:length(reducVec))=reducVec;
edgeRepressor(end-length(reducVec)+1:end)=fliplr(reducVec);
tempe=HB-repmat(mean(HB(:,[1:ms20,end-ms20:end]),2),1,size(HB,2));
tempe=tempe.*repmat(edgeRepressor,size(HB,1),1);
function MCG=makeMCGbyCh(temp,maxTemp,Rlims,Ipeaks,amp,lengt)
MCG=zeros(size(temp,1),lengt);
for HBi=1:length(Ipeaks);
    s0=Ipeaks(HBi)-maxTemp+1;
    s1=Ipeaks(HBi)+length(temp)-maxTemp;
    if sum(MCG(1,s0:s1))>0
        overlap=find(MCG(1,s0:s1),1,'last');
        if overlap>0.2*size(temp,2)
            endPrev=round(0.2*size(temp,2));
        else
            endPrev=overlap;
        end
%         sampDif=round(sRate/50);
        reducVec=1:-1/endPrev:1/endPrev;
        reducVecLR=fliplr(reducVec);
        reducVec(end+1:size(temp,2))=0;
        reducVecLR(end+1:size(temp,2))=1;
        reducVec=repmat(reducVec,size(temp,1),1);
        reducVecLR=repmat(reducVecLR,size(temp,1),1);
        MCG(:,s0:s1)=MCG(:,s0:s1).*reducVec+temp.*reducVecLR;
    else
        MCG(:,s0:s1)=MCG(:,s0:s1)+temp;
    end
    MCG(:,s0+Rlims(1)-1:s0+Rlims(2)-1)=temp(:,Rlims(1):Rlims(2))*amp(HBi);
end
function xcr=XCORR(x,y,Rsamp)
xcorrByseg=false;
if length(x)>=2^20 % test if version is later than 1011b
    ver=version('-release');
    if ~strcmp(ver,'2011b')
        if str2num(ver(1:end-1))<=2011
            xcorrByseg=true;
        end
    end
end
[~,Rsamp]=max(y);
if xcorrByseg
    trace1=x;
    xcr=[];
    
    while length(trace1)>length(y)%2^20
        if length(trace1)>2^20
            trace2=trace1(1:2^20);
            trace1=trace1(2^20+1:end);
        else
            trace2=trace1;
            trace1=0;
        end
        xcrPad=zeros(size(trace2));
        [xcCurrent,lags]=xcorr(trace2,y);
        xcCurrent=xcCurrent(lags>=0);
        xcrPad=zeros(size(trace2));
        xcrPad(Rsamp:end)=xcCurrent(1:end-Rsamp+1);
        xcr=[xcr,xcrPad];
        % FIXME xcorr (fftfilt) won't take it for more than 2^20
    end
    
else
    [xcr,lags]=xcorr(x,y);
    xcr=xcr(lags>=0);
    xcrPad=zeros(size(x));
    xcrPad(Rsamp:end)=xcr(1:end-Rsamp+1);
    xcr=xcrPad; % sorry for switching variables
end
function [p,Rlims]=assessAmp(temp2e,maxi,Ipeaks2in,meanMEG)
%[~,maxi]=max(temp2e(1:round(length(temp2e/2))));
bef=find(fliplr(temp2e(1:maxi))<0,1)-1;
aft=find(temp2e(maxi:end)<0,1)-1;
Rlims=[maxi-bef,maxi+aft]; % check where R pulls the template above zero
for HBi=1:length(Ipeaks2in);
    s0=Ipeaks2in(HBi)-bef;
    s1=Ipeaks2in(HBi)+aft;
    x=temp2e(Rlims(1):Rlims(2));
    y=meanMEG(s0:s1);
    scalef=-round(log10(max([x,y]))); % scaling factor for polyfit not to complain
    x=x*10^scalef;
    y=y*10^scalef;
    pScaled=polyfit(x,y,1);
    pScaled(2)=pScaled(2).*10^-scalef;
    p(HBi,1:2)=pScaled; %#ok<AGROW>
end
function variable=default(field,value,cfg)
if isfield(cfg,field)
    eval(['variable=cfg.',field,';'])
else
    variable=value;
end
function vecN=standard(vec) % normalize data for display
vecN=vec/median(abs(vec));
