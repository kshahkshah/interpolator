# Copyright (c) 2009 Eric Todd Meyers
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
#
# More information, source code and gems @ http://rubyforge.org/projects/interpolator/
#
#
module Interpolator

  # Table holds a series of independent and dependent values that can be interpolated or extrapolated.
  # The independent values are always floating points numbers. The dependent values can either be floating point
  # numbers or themselves Table instances. By nesting the Table in this way a Table of any dimension can be
  # created.
  #
  # Tables can be told to not extrapolate by setting .extrapolate=false
  # The interpolation method is controlled with .style = LINEAR, LAGRANGE2, LAGRANGE3, CUBIC (also known as natural spline), or CATMULL (spline)
  #
  # The style and extrapolate attributes are only applied to that specific Table. They are not propagated to subtables. Each subtable
  # can of course accept it's own attributes.
  #
  # More information, source code and gems @ http://rubyforge.org/projects/interpolator/
  #
  class Table

    attr_accessor :extrapolate,:style

    LINEAR    = 1
    LAGRANGE2 = 2
    LAGRANGE3 = 3
    CUBIC     = 4
    CATMULL   = 5

    #
    # Tables are constructed from either a pair of Arrays or a single Hash.
    #
    # The 2 argument constructor accepts an array of independents and an array of dependents. The
    # independent Array should be floating point values. The dependent Array can be either floating
    # point values or Tables (aka sub tables.) There is no limit to how deep a Table can be.
    #
    # The single argument constructor is similar. The keys of the Hash are the independents. The values
    # of the Hash are the dependent values, and can either be floating point numbers or Tables.
    #
    # Examples
    # * simple univariant table
    #
    #          t = Table.new [1.0,2.0],[3.0,4.0]
    #          and is equivalent to
    #          t = Table.new(1.0=>3.0,2.0=>4.0)
    #
    #          set attributes inline
    #          t = Table.new([1.0,2.0],[3.0,4.0]) do |tab| tab.extrapolate=false end
    #
    # * bivariant table
    #
    #          t = Table.new([1.0,2.0],[Table.new([1.0,2.0],[3.0,4.0]),Table.new([2.0,3.0,5.0],[6.0,-1.0,7.0])])
    #
    # * trivariant table
    #
    #          t = Table.new(
    #                    1=>Table.new(
    #                      1=>Table.new([1.0,2.0,3.0],[4.0,5.0,6.0]),
    #                      4=>Table.new([11.0,12.0,13.0],[14.0,15.0,16.0]),
    #                      5=>Table.new([11.0,12.0,13.0],[-14.0,-15.0,-16.0])),
    #                    2=>Table.new(
    #                      2=>Table.new([1.1,2.0,3.0],[4.0,5.0,6.0]),
    #                      5=>Table.new([11.0,12.5,13.0],[14.0,15.0,16.0]),
    #                      6.2=>Table.new([1.0,12.0],[-14.0,-16.0])),
    #                    8=>Table.new(
    #                      1=>Table.new([1.0,2.0,3.0],[4.0,5.0,6.0]),
    #                      5=>Table.new([11.0,12.0,13.0],[-14.0,-15.0,-16.0]))
    #                  )
    #
    #             Note: notice how the Hash version of the table constructor makes it easier to view multidimensional Tables.
    #
    #
    # The amount of Table nesting is only limited by RAM.
    #
    # As a convienance the constructor accepts a block and will pass back the
    # Table instance. This makes it easy to set the style and extrapolation inline.
    # For example,
    #
    #       tabfoo = Table.new [1,2,3],[4,5.5,6] do |t| t.extrapolate=false end
    #
    #
    def initialize (*args)
      if (args.size==2) then
        raise "duel argument table constructor must be 2 Arrays" unless args[0].kind_of? Array
        raise "duel argument table constructor must be 2 Arrays" unless args[1].kind_of? Array
        @inds = args[0]          # better be numbers
        @deps = args[1]          # can either be numbers or sub tables
      elsif (args.size == 1) then  # hash version
        raise "single argument table constructor must be a Hash" unless args[0].kind_of? Hash
        # Ruby 1.8 doesnt maintain hash order so lets help it
        f = args[0].sort.transpose
        @inds = f[0]
        @deps = f[1]
      else
        raise(args.size.to_s + " argument Table constructor not valid");
      end

      raise "number of independents must equal the number of dependents" unless @inds.size == @deps.size
      ii = nil
      @inds.each do |i|
        raise "independents must be monotonically increasing" unless (ii == nil || i > ii)
        ii = i
      end
      @extrapolate = true
      @style       = LINEAR
      @ilast       = 0    # index of last bracket operation. theory is subsequent table reads may be close to this index so remember it
      @secderivs   = []

      if block_given?
        yield self        # makes it easy for users to set Table attributes inline
      end

    end
    #
    # Interpolate or extrapolate the Table. Pass as many arguments as there are independent dimensions to the table (univariant a
    # single argument, bivariant 2 arguments, etc.)
    #
    # Examples
    # * univariant
    #     t = Table.new [1.0,2.0],[3.0,4.0]
    #     t.read(1.5)  returns 3.5
    # * bivariant
    #     t = Table.new([1.0,2.0],[Table.new([1.0,2.0],[3.0,4.0]),Table.new([2.0,3.0,5.0],[6.0,-1.0,7.0])])
    #     t.read(2.0,3.0) returns -1.0
    #     t.read(1.7,2.0) returns 5.4
    #
    def read(*args)
      raise "table requires at least 2 points for linear interpolation" if (@style == LINEAR && @inds.size<2)
      raise "table requires at least 3 points for lagrange2 interpolation" if (@style == LAGRANGE2 && @inds.size<3)
      raise "table requires at least 4 points for lagrange3 interpolation" if (@style == LAGRANGE3 && @inds.size<4)
      raise "table requires at least 3 points for cubic spline interpolation" if (@style == CUBIC && @inds.size<3)
      raise "table requires at least 2 points for catmull-rom interpolation" if (@style == CATMULL && @inds.size<2)
      raise "insufficient number of arguments to read table" unless args.size>=1
      raise "insufficient number of arguments to read table" if (args.size==1 && @deps[0].kind_of?(Table))
      raise "too many arguments to read table" if (args.size>1 && !@deps[0].kind_of?(Table))

      xval    = args[0]
      subargs = args[1..-1]

      if (@extrapolate == false) && (xval < @inds[0]) then
        ans = subread(0,*subargs)
      elsif (@extrapolate == false) && (xval > @inds[-1])
        ans = subread(-1,*subargs)
      else

        ileft = bracket(xval)

        case @style
        when LINEAR
          x1 = @inds[ileft]
          x2 = @inds[ileft+1]
          y1 = subread(ileft,*subargs)
          y2 = subread(ileft+1,*subargs)
          ans = linear(xval,x1,x2,y1,y2)

        when LAGRANGE2
          indx = ileft
          if ileft == @inds.size-2
            indx = ileft - 1
          end
          x1  = @inds[indx]
          x2  = @inds[indx+1]
          x3  = @inds[indx+2]
          y1  = subread(indx,*subargs)
          y2  = subread(indx+1,*subargs)
          y3  = subread(indx+2,*subargs)
          ans = lagrange2(xval,x1,x2,x3,y1,y2,y3)

        when LAGRANGE3
          indx = ileft

          if (ileft > @inds.size-3)
            indx = @inds.size - 3;
          elsif (ileft  == 0)
            indx = ileft + 1
          end

          x1  = @inds[indx-1]
          x2  = @inds[indx]
          x3  = @inds[indx+1]
          x4  = @inds[indx+2]
          y1  = subread(indx-1,*subargs)
          y2  = subread(indx,*subargs)
          y3  = subread(indx+1,*subargs)
          y4  = subread(indx+2,*subargs)
          ans = lagrange3(xval,x1,x2,x3,x4,y1,y2,y3,y4)

        when CUBIC
          indx = ileft
          x1   = @inds[indx]
          x2   = @inds[indx+1]
          y1   = subread(indx,*subargs)
          y2   = subread(indx+1,*subargs)
          ans  = cubic(xval,indx,x1,x2,y1,y2,*subargs)

        when CATMULL
          indx  = ileft
          tinds = @inds.dup              # were gonna prepend and append 2 control points temporarily
          tdeps = @deps.dup
          tinds.insert(0,@inds[0])
          tinds << @inds[-1]
          tdeps.insert(0,@deps[0])
          tdeps << @deps[-1]
          indx  = indx+1
          x0    = tinds[indx-1]
          x1    = tinds[indx]
          x2    = tinds[indx+1]
          x3    = tinds[indx+2]
          y0    = catsubread(indx-1,tdeps,*subargs)
          y1    = catsubread(indx,tdeps,*subargs)
          y2    = catsubread(indx+1,tdeps,*subargs)
          y3    = catsubread(indx+2,tdeps,*subargs)
          ans   = catmull(xval,x0,x1,x2,x3,y0,y1,y2,y3)
        else
          raise("invalid interpolation type")
        end
      end
      ans
    end

    #
    #  Same as read
    #
    alias_method :interpolate,:read

    #
    # Human readable form of the Table. Pass a format string for the values to use. The default is %12.4f
    #
    def inspect(format="%12.4f",indent=0)
      indt = "   " * indent
      s = ""
      if @deps[0].kind_of? Table
        @inds.each_index do |i|
          s << indt << format % @inds[i]
          s << "\n"
          s << @deps[i].inspect(format,indent+1)
          s << "\n" if i!=(@inds.size-1)
        end
      else
        s << indt
        @inds.each_index do |i|
          s << format % @inds[i]
        end
        s << "\n"
        s << indt
        @deps.each_index do |i|
          s << format % @deps[i]
        end
      end
      s
    end

    #########
    protected
    #########

    def subread (i,*subargs)
      if subargs == []
        @deps[i]
      else
        @deps[i].read(*subargs)
      end
    end

    def catsubread (i,tdeps,*subargs)
      if subargs == []
        tdeps[i]
      else
        tdeps[i].read(*subargs)
      end
    end

    #
    # high speed bracket via last index and bisection
    #
    def bracket (x)
      if (x<=@inds[0])
        @ilast=0
      elsif (x>=@inds[-2])
        @ilast = @inds.size-2
      else
        low  = 0
        high = @inds.size-1
        while !(x>=@inds[@ilast] && x<@inds[@ilast+1])
          if (x>@inds[@ilast])
            low    =  @ilast + 1
            @ilast = (high - low) / 2 + low
          else
            high    =  @ilast - 1
            @ilast = high - (high - low) / 2
          end
        end
      end
      @ilast
    end

    def linear (x,x1,x2,y1,y2)
      r = (y2-y1) / (x2-x1) * (x-x1) + y1
    end

    def lagrange2(x,x1,x2,x3,y1,y2,y3)
      c12 = x1 - x2
      c13 = x1 - x3
      c23 = x2 - x3
      q1  = y1/(c12*c13)
      q2  = y2/(c12*c23)
      q3  = y3/(c13*c23)
      xx1 = x - x1
      xx2 = x - x2
      xx3 = x - x3
      r   = xx3*(q1*xx2 - q2*xx1) + q3*xx1*xx2
    end

    def lagrange3(x,x1,x2,x3,x4,y1,y2,y3,y4)
      c12 = x1 - x2
      c13 = x1 - x3
      c14 = x1 - x4
      c23 = x2 - x3
      c24 = x2 - x4
      c34 = x3 - x4
      q1  = y1/(c12 * c13 * c14)
      q2  = y2/(c12 * c23 * c24)
      q3  = y3/(c13 * c23 * c34)
      q4  = y4/(c14 * c24 * c34)
      xx1 = x - x1
      xx2 = x - x2
      xx3 = x - x3
      xx4 = x - x4
      r   = xx4*(xx3*(q1*xx2 - q2*xx1) + q3*xx1*xx2) - q4*xx1*xx2*xx3
    end

    def catmull(xval,x0,x1,x2,x3,y0,y1,y2,y3)
      m0  = (y2-y0)/(x2-x0)
      m1  = (y3-y1)/(x3-x1)
      h   = x2-x1
      t   = (xval - x1)/h
      h00 = 2.0*t**3 - 3.0*t**2+1.0
      h10 = t**3-2.0*t**2+t
      h01 = -2.0*t**3+3.0*t**2
      h11 = t**3-t**2
      ans = h00*y1+h10*h*m0+h01*y2+h11*h*m1
    end

    def cubic(x,indx,x1,x2,y1,y2,*subargs)
      if @secderivs == []
        @secderivs = second_derivs(*subargs)  # this is painful so lets just do it once
      end
      step = x2 - x1
      a    = (x2 - x) / step
      b    = (x - x1) / step
      r    = a * y1 + b * y2 + ((a*a*a-a) * @secderivs[indx] + (b*b*b-b) * @secderivs[indx+1]) * (step*step) / 6.0
    end

    def second_derivs(*subargs)
      # natural spline has 0 second derivative at the ends
      temp   = [0.0]
      secder = [0.0]
      if subargs.size==0
        deps2 = @deps
      else
        deps2 = @deps.map do |a|
          a.read(*subargs)
        end
      end
      1.upto(@inds.size-2) do |i|
        sig  = (@inds[i] - @inds[i-1])/(@inds[i+1] - @inds[i-1])
        prtl = sig * secder[i-1] + 2.0
        secder << (sig-1.0)/prtl
        temp << ((deps2[i+1]-deps2[i])/(@inds[i+1]-@inds[i]) - (deps2[i]-deps2[i-1])/(@inds[i]-@inds[i-1]))
        temp[i]=(6.0*temp[i]/(@inds[i+1]-@inds[i-1])-sig*temp[i-1])/prtl
      end
      # natural spline has 0 second derivative at the ends
      secder << 0.0
      (@inds.size-2).downto(0) do |i|
        secder[i]=secder[i]*secder[i+1]+temp[i]
      end
      secder
    end
  end

  if __FILE__ == $0 then

    require 'test/unit'
    #
    # Unit test for Table class
    #
    class TC_LookupTest < Test::Unit::TestCase
      def setup
        @t1 = Table.new [1.0,2.0],[3.0,4.0]
        @t2 = Table.new([1.0,2.0],[Table.new([1.0,2.0],[3.0,4.0]),Table.new([2.0,3.0,5.0],[6.0,-1.0,7.0])])
        @t3 = Table.new [1.0,2.0],[3.0,4.0]
        @t4 = Table.new(
          1.0=>Table.new(
            1.0=>Table.new([1.0,2.0,3.0],[4.0,5.0,6.0]),
            4.0=>Table.new([11.0,12.0,13.0],[14.0,15.0,16.0]),
            5.0=>Table.new([11.0,12.0,13.0],[-14.0,-15.0,-16.0])),
          2.0=>Table.new(2.0=>Table.new([1.1,2.0,3.0],[4.0,5.0,6.0]),
            5.0=>Table.new([11.0,12.5,13.0],[14.0,15.0,16.0]),
            6.2=>Table.new([1.0,12.0],[-14.0,-16.0])),
          8.0=>Table.new(
            1.0=>Table.new([1.0,2.0,3.0],[4.0,5.0,6.0]),
            5.0=>Table.new([11.0,12.0,13.0],[-14.0,-15.0,-16.0])))
        @t5 = Table.new [1.0,2.0,3.0],[1.0,4.0,9.0]
        @t6 = Table.new [1.0,2.0,3.0,4.0],[1.0,8.0,27.0,64.0]
        @t7 = Table.new [0.0,0.8,1.9,3.1,4.2,5.0],[1.0,1.0,1.0,2.0,2.0,2.0]
        @t8 = Table.new [0.0,1.0,2.0,3.0,4.0,5.0,6.0],[0.0,0.8415,0.9093,0.1411,-0.7568,-0.9589,-0.2794]
        @t9 = Table.new([1.0,2.0,3.0],[Table.new([1.0,2.0],[3.0,4.0]),Table.new([2.0,3.0,5.0],[6.0,-1.0,7.0]),Table.new([4.0,5.0,6.0],[7.0,8.0,9.0])])
        @t10 = Table.new [1.5,2.0,3.0,4.0],[4.0,5.0,6.0,7.0]
      end

      def test_uni
        assert_equal(@t1.read(1.0) ,3.0)
        assert_equal(@t1.read(2.0) ,4.0)
        assert_equal(@t1.read(1.5) ,3.5)
      end

      def test_bi
        assert_equal(@t2.read(1.0,1.0) , 3.0)
        assert_equal(@t2.read(2.0,3.0) ,-1.0)
        assert_equal(@t2.read(1.5,2.0) , 5.0)
      end

      def test_tri
        assert_equal(@t4.read(1.5,5,13),0.0)
      end

      def test_create
        assert_nothing_raised{
          Table.new(1.0=>3.0,2.0=>4.0)
        }
        assert_nothing_raised( RuntimeError ){
          Table.new(
            1=>Table.new([1.0,2.0,3.0],[4.0,5.0,6.0]),
            2=>Table.new([2.0,4.0,7.0],[14.0,15.0,16.0]))
        }
        assert_nothing_raised( RuntimeError ){
          Table.new(
             1=>Table.new([1.0,2.0,3.0],[4.0,5.0,6.0]),
             2=>Table.new([2.0,4.0,7.0],[14.0,15.0,16.0]))
        }
        assert_nothing_raised( RuntimeError ){
          Table.new 1=>Table.new(1.0=>4.0,2.0=>5.0,3.0=>6.0),2=>Table.new([2.0,4.0,7.0,12.0],[14.0,15.0,16.0,-4.0])
        }
        assert_raise( RuntimeError ) {Table.new(1,2,3)}
      end

      def test_size
        @t3.style=Table::LAGRANGE2
        assert_raise( RuntimeError ) {@t3.read(1.0)}
        @t3.style=Table::LAGRANGE3
        assert_raise( RuntimeError ) {@t3.read(1.0)}
        @t3.style=Table::CUBIC
        assert_raise( RuntimeError ) {@t3.read(1.0)}
        @t3.style=Table::LINEAR
        assert_nothing_raised( RuntimeError ) {@t3.read(1)}
      end

      def test_notmono
        assert_raise( RuntimeError ) {Table.new [1.0,2.0,1.5],[1.0,2.0,3.0]}
        assert_raise( RuntimeError ) {Table.new [1.0,-2.0,1.5],[1.0,2.0,3.0]}
      end

      def test_extrap
        @t1.extrapolate = false
        assert_equal(@t1.read(0.0) , 3.0)
        assert_equal(@t1.read(3.0) , 4.0)
        @t1.extrapolate = true
        assert_equal(@t1.read(0.0) , 2.0)
        assert_equal(@t1.read(3.0) , 5.0)
      end

      def test_style
        @t5.style=Table::LAGRANGE2
        assert_equal(@t5.read(2.0),4.0)
        assert_equal(@t5.read(2.5),2.5*2.5)
        @t6.style=Table::LAGRANGE3
        assert_equal(@t6.read(2.0),8.0)
        assert_equal(@t6.read(3.5),3.5*3.5*3.5)
        @t5.style=Table::LINEAR
        assert_equal(@t5.read(1.5),2.5)
        @t6.style=Table::LINEAR
        assert_equal(@t6.read(1.5),4.5)
        assert_raise( RuntimeError ) {
          t = Table.new [1.0,-2.0,1.5],[1.0,2.0,3.0]
          t.style=10
          t.read(1.0)
        }
        @t7.style = Table::CUBIC
        assert_in_delta(0.93261392,@t7.read(1.2),0.000001)
        @t8.style = Table::CUBIC
        assert_in_delta(0.59621,@t8.read(2.5),0.000001)
        @t9.style = Table::CUBIC
        assert_in_delta(8.98175,@t9.read(2.3,1.5),0.000001)
        @t10.style=Table::CATMULL
        assert_in_delta(3.666666,@t10.read(1.0),0.00001)
        assert_in_delta(5.5416666,@t10.read(2.5),0.00001)
        assert_in_delta(6.0,@t10.read(0.5),0.00001)
        assert_in_delta(8.0,@t10.read(5.0),0.00001)
        assert_in_delta(6.5,@t10.read(3.5),0.00001)
        assert_in_delta(4.8427,@t10.read(1.9),0.0001)
        @t10.extrapolate=false
        assert_equal(4.0,@t10.read(1.0))
        assert_equal(7.0,@t10.read(99.0))
      end

      def test_block
        t = Table.new [1.0,2.0,3.0],[3.0,4.0,5.0] do |tab| tab.extrapolate=false;tab.style=Table::LAGRANGE2 end
        assert_equal(t.read(4.0),5.0)
      end

      def test_alias
        assert_equal(@t1.read(1.5),@t1.interpolate(1.5))
      end

      def test_numargs
        assert_raise( RuntimeError ) {@t1.read}
        assert_raise( RuntimeError ) {@t2.read(1.0)}
        assert_raise( RuntimeError ) {@t2.read(1.0,1.0,1.0)}
        assert_nothing_raised( RuntimeError ) {@t2.read(1.0,1.0)}
      end
      def test_inspect
        s=
"      1.0000
         1.0000
            1.0000      2.0000      3.0000
            4.0000      5.0000      6.0000
         4.0000
           11.0000     12.0000     13.0000
           14.0000     15.0000     16.0000
         5.0000
           11.0000     12.0000     13.0000
          -14.0000    -15.0000    -16.0000
      2.0000
         2.0000
            1.1000      2.0000      3.0000
            4.0000      5.0000      6.0000
         5.0000
           11.0000     12.5000     13.0000
           14.0000     15.0000     16.0000
         6.2000
            1.0000     12.0000
          -14.0000    -16.0000
      8.0000
         1.0000
            1.0000      2.0000      3.0000
            4.0000      5.0000      6.0000
         5.0000
           11.0000     12.0000     13.0000
          -14.0000    -15.0000    -16.0000"
        assert_equal(s,@t4.inspect)
        s=
"    1.00
       1.00
          1.00    2.00    3.00
          4.00    5.00    6.00
       4.00
         11.00   12.00   13.00
         14.00   15.00   16.00
       5.00
         11.00   12.00   13.00
        -14.00  -15.00  -16.00
    2.00
       2.00
          1.10    2.00    3.00
          4.00    5.00    6.00
       5.00
         11.00   12.50   13.00
         14.00   15.00   16.00
       6.20
          1.00   12.00
        -14.00  -16.00
    8.00
       1.00
          1.00    2.00    3.00
          4.00    5.00    6.00
       5.00
         11.00   12.00   13.00
        -14.00  -15.00  -16.00"        
        assert_equal(s,@t4.inspect("%8.2f"))
        s=
"      1.0000
         1.0000      2.0000
         3.0000      4.0000
      2.0000
         2.0000      3.0000      5.0000
         6.0000     -1.0000      7.0000"        
        assert_equal(s,@t2.inspect)
        s=
"      1.0000      2.0000
      3.0000      4.0000"      
        assert_equal(s,@t1.inspect)
      end
    end
  end
end
