function [fourier,freq]=fftBasic(rows,Fs,binSize)
% rows = data with rows for channels
% Fs = Sampling frequency
% binSize = how many Hz per freq bin, default is one.
if ~exist('binSize','var')
    binSize=1;
elseif isempty(binSize)
    binSize=1;
end
L = size(rows,2)/Fs;                     % Length of signal
NFFT = round(Fs)/binSize; % this gives bins of roughly  1Hz
Y = fft(rows',NFFT);
fourier=Y(1:floor(NFFT/2)+1,:);
freq = Fs/2*linspace(0,1,NFFT/2+1);
fourier=fourier';
freq=freq(2:end);
fourier=fourier(:,2:end);
end